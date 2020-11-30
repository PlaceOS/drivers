module Cisco; end

require "set"
require "s2_cells"
require "simple_retry"
require "placeos-driver/interface/locatable"

class Cisco::DNASpaces < PlaceOS::Driver
  include Interface::Locatable

  # Discovery Information
  descriptive_name "Cisco DNA Spaces"
  generic_name :DNA_Spaces
  uri_base "https://partners.dnaspaces.io"

  default_settings({
    dna_spaces_api_key: "X-API-KEY",
    tenant_id:          "sfdsfsdgg",

    # Time before a user location is considered probably too old (in minutes)
    max_location_age: 10,
  })

  def on_load
    on_update
    spawn(same_thread: true) { start_streaming_events }
  end

  def on_unload
    @terminated = true
    @channel.close
  end

  @api_key : String = ""
  @tenant_id : String = ""
  @terminated : Bool = false
  @channel : Channel(String) = Channel(String).new
  @max_location_age : Time::Span = 10.minutes
  @s2_level : Int32 = 21
  @floorplan_mappings : Hash(String, Hash(String, String)) = Hash(String, Hash(String, String)).new
  @debug_stream : Bool = false
  @events_received : UInt64 = 0_u64

  def on_update
    @api_key = setting(String, :dna_spaces_api_key)
    @tenant_id = setting(String, :tenant_id)
    @max_location_age = (setting?(UInt32, :max_location_age) || 10).minutes
    @s2_level = setting?(Int32, :s2_level) || 21
    @floorplan_mappings = setting?(Hash(String, Hash(String, String)), :floorplan_mappings) || @floorplan_mappings
    @debug_stream = setting?(Bool, :debug_stream) || false

    schedule.clear
    schedule.every(30.minutes) { cleanup_caches }
  end

  class LocationInfo
    include JSON::Serializable

    getter location : Location

    @[JSON::Field(key: "locationDetails")]
    getter details : LocationDetails
  end

  def get_location_info(location_id : String)
    response = get("/api/partners/v1/locations/#{location_id}?partnerTenantId=#{@tenant_id}", headers: {
      "X-API-KEY" => @api_key,
    })

    raise "failed to obtain location id #{location_id}, code #{response.status_code}" unless response.success?
    LocationInfo.from_json(response.body.not_nil!)
  end

  @description_lock : Mutex = Mutex.new
  @location_descriptions : Hash(String, String) = {} of String => String

  def seen_locations
    @description_lock.synchronize { @location_descriptions.dup }
  end

  # MAC Address => Location (including user)
  @locations : Hash(String, DeviceLocationUpdate) = {} of String => DeviceLocationUpdate
  @loc_lock : Mutex = Mutex.new

  def locations
    @loc_lock.synchronize { yield @locations }
  end

  @user_lookup : Hash(String, Set(String)) = {} of String => Set(String)
  @user_loc : Mutex = Mutex.new

  def user_lookup
    @user_loc.synchronize { yield @user_lookup }
  end

  def user_lookup(user_id : String)
    formatted_user = format_username(user_id)
    user_lookup { |lookup| lookup[formatted_user]? }
  end

  def locate_mac(address : String)
    formatted_address = format_mac(address)
    locations { |locs| locs[formatted_address]? }
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def inspect_state
    logger.debug {
      "MAC Locations: #{locations &.keys}"
    }
    {tracking: locations &.size, events_received: @events_received}
  end

  @map_details : Hash(String, MapInfo) = {} of String => MapInfo
  @map_lock : Mutex = Mutex.new

  def get_map_details(map_id : String)
    map = @map_lock.synchronize { @map_details[map_id]? }
    if !map
      response = get("/api/partners/v1/maps/#{map_id}?partnerTenantId=#{@tenant_id}", headers: {
        "X-API-KEY" => @api_key,
      })
      if !response.success?
        message = "failed to obtain map id #{map_id}, code #{response.status_code}"
        logger.warn { message }
        return nil
      end
      map = MapInfo.from_json(response.body.not_nil!)
      @map_lock.synchronize { @map_details[map_id] = map }
    end
    map
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def cleanup_caches : Nil
    logger.debug { "removing location data that is over 30 minutes old" }

    old = 30.minutes.ago.to_unix
    remove_keys = [] of String
    locations do |locs|
      locs.each { |mac, location| remove_keys << mac if location.last_seen < old }
      remove_keys.each { |mac| locs.delete(mac) }
    end

    logger.debug { "removed #{remove_keys.size} MACs" }
    nil
  end

  # we want to stream events until driver is terminated
  protected def start_streaming_events
    SimpleRetry.try_to(
      base_interval: 10.milliseconds,
      max_interval: 5.seconds
    ) { stream_events unless @terminated }
  end

  # as sometimes the map id is missing, but in the same location
  # location id => map id
  @location_id_maps = {} of String => String

  # Processes events as they come in, forces a disconnect if no events are sent
  # for a period of time as the remote should be sending them periodically
  protected def process_events(client)
    loop do
      select
      when data = @channel.receive
        logger.debug { "received push #{data}" } if @debug_stream
        @events_received = @events_received &+ 1_u64
        begin
          event = Cisco::DNASpaces::Events.from_json(data)
          payload = event.payload
          case payload
          when DeviceExit
            device_mac = format_mac(payload.device.mac_address)
            locations &.delete(device_mac)
          when DeviceEntry
            # This is used entirely for
            @description_lock.synchronize { payload.location.descriptions(@location_descriptions) }
          when DeviceLocationUpdate
            # Keep track of device location
            device_mac = format_mac(payload.device.mac_address)
            existing = nil

            # ignore locations where we don't have enough details to put the device on a map
            if payload.map_id.presence
              @location_id_maps[payload.location.location_id] = payload.map_id
            else
              found = ""
              payload.location_mappings.values.each do |loc_id|
                if map_id = @location_id_maps[loc_id]?
                  payload.map_id = map_id
                  found = loc_id
                  break
                end
              end

              if found.empty?
                logger.debug { "ignoring device #{device_mac} location as map_id is empty, location id #{payload.location.location_id}, visit #{payload.visit_id}" }
                next
              end
            end

            locations do |loc|
              existing = loc[device_mac]?
              loc[device_mac] = payload
            end

            # Maintain user lookup
            if payload.raw_user_id.presence
              user_id = format_username(payload.raw_user_id)

              if existing && payload.raw_user_id != existing.raw_user_id
                old_user_id = format_username(existing.raw_user_id)

                user_lookup do |lookup|
                  lookup[old_user_id]?.try &.delete(device_mac)
                  devices = lookup[old_user_id]? || Set(String).new
                  devices.delete(device_mac)
                  lookup.delete(old_user_id) if devices.empty?

                  devices = lookup[user_id]? || Set(String).new
                  devices << device_mac
                  lookup[user_id] = devices
                end
              else
                user_lookup do |lookup|
                  devices = lookup[user_id]? || Set(String).new
                  devices << device_mac
                  lookup[user_id] = devices
                end
              end
            end

            # payload.location_mappings => { "ZONE" => loc_id, "FLOOR" => loc_id, "BUILDING" => loc_id, "CAMPUS" => loc_id }
          else
            logger.debug { "ignoring event: #{payload ? payload.class : event.class}" }
          end
        rescue error
          logger.error(exception: error) { "parsing DNA Spaces event: #{data}" }
        end
      when timeout(20.seconds)
        logger.debug { "no events received for 20 seconds, expected heartbeat at 15 seconds" }
        @channel.close
        break
      end
    end
  ensure
    client.close
  end

  protected def stream_events
    client = HTTP::Client.new URI.parse(config.uri.not_nil!)
    client.get("/api/partners/v1/firehose/events", HTTP::Headers{
      "X-API-KEY" => @api_key,
    }) do |response|
      if !response.success?
        logger.warn { "failed to connect to firehose api #{response.status_code}" }
        raise "failed to connect to firehose api #{response.status_code}"
      end

      # We use a channel for event processing so we can make use of timeouts
      @channel = Channel(String).new
      spawn(same_thread: true) { process_events(client) }

      begin
        loop do
          if response.body_io.closed?
            @channel.close
            break
          end

          if data = response.body_io.gets
            @channel.send data
          else
            @channel.close
            break
          end
        end
      rescue IO::Error
        @channel.close
      end
    end

    # Trigger the retry behaviour
    raise "stream closed"
  end

  # =============================
  # Locatable interface
  # =============================
  def locate_user(email : String? = nil, username : String? = nil)
    if macs = user_lookup(username.presence || email.presence.not_nil!)
      location_max_age = @max_location_age.ago.to_unix

      macs.compact_map { |mac|
        if location = locate_mac(mac)
          if location.last_seen > location_max_age
            # we update the mac_address to a formatted version
            location.device.mac_address = mac
            location
          end
        end
      }.sort { |a, b|
        b.last_seen <=> a.last_seen
      }.map { |location|
        lat = location.latitude
        lon = location.longitude

        loc = {
          "location"         => "wireless",
          "coordinates_from" => "bottom-left",
          "x"                => location.x_pos,
          "y"                => location.y_pos,
          "lon"              => lon,
          "lat"              => lat,
          "s2_cell_id"       => S2Cells::LatLon.new(lat, lon).to_token(@s2_level),
          "mac"              => location.device.mac_address,
          "variance"         => location.unc,
          "last_seen"        => location.last_seen,
          "dna_floor_id"     => location.map_id,
          "ssid"             => location.ssid,
          "manufacturer"     => location.device.manufacturer,
          "os"               => location.device.os,
        }

        # Add meraki map information to the response
        if map_size = get_map_details(location.map_id)
          loc["map_width"] = map_size.image_width
          loc["map_height"] = map_size.image_height
        end

        # Add our zone IDs to the response
        location.location_mappings.each do |tag, location_id|
          if level_data = @floorplan_mappings[location_id]?
            level_data.each { |k, v| loc[k] = v }
            break
          end
        end

        loc
      }
    else
      [] of Nil
    end
  end

  # Will return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    user_lookup(username.presence || email.presence.not_nil!).try(&.to_a) || [] of String
  end

  # Will return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String) : OwnershipMAC?
    if location = locate_mac(mac_address)
      {
        location:    "wireless",
        assigned_to: format_username(location.raw_user_id),
        mac_address: format_mac(mac_address),
      }
    end
  end

  # Will return an array of devices and their x, y coordinates
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "looking up device locations in #{zone_id}" }
    return [] of Nil if location.presence && location != "wireless"

    # Find the floors associated with the provided zone id
    floors = [] of String
    @floorplan_mappings.each do |floor_id, data|
      floors << floor_id if data.values.includes?(zone_id)
    end
    logger.debug { "found matching meraki floors: #{floors}" }
    return [] of Nil if floors.empty?

    checking_count = @locations.size
    wrong_floor = 0
    too_old = 0

    # Find the devices that are on the matching floors
    oldest_location = @max_location_age.ago.to_unix

    matching = locations(&.compact_map { |mac, loc|
      if loc.last_seen < oldest_location
        too_old += 1
        next
      end
      if (floors & loc.location_mappings.values).empty?
        wrong_floor += 1
        next
      end

      # ensure the formatted mac is being used
      loc.device.mac_address = mac
      loc
    })

    logger.debug { "found #{matching.size} matching devices\nchecked #{checking_count} locations, #{wrong_floor} were on the wrong floor, #{too_old} were too old" }

    matching.group_by(&.map_id).flat_map { |map_id, locations|
      map_width = -1.0
      map_height = -1.0

      if map_size = get_map_details(map_id)
        map_width = map_size.image_width
        map_height = map_size.image_height
      end

      locations.map do |loc|
        lat = loc.latitude
        lon = loc.longitude

        {
          location:         :wireless,
          coordinates_from: "bottom-left",
          x:                loc.x_pos,
          y:                loc.y_pos,
          lon:              lon,
          lat:              lat,
          s2_cell_id:       S2Cells::LatLon.new(lat, lon).to_token(@s2_level),
          mac:              loc.device.mac_address,
          variance:         loc.unc,
          last_seen:        loc.last_seen,
          map_width:        map_width,
          map_height:       map_height,
          ssid:             loc.ssid,
          manufacturer:     loc.device.manufacturer,
          os:               loc.device.os,
        }
      end
    }
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def format_username(user : String)
    if user.includes? "@"
      user = user.split("@")[0]
    elsif user.includes? "\\"
      user = user.split("\\")[1]
    end
    user.downcase
  end
end

require "./dna_spaces/events"
