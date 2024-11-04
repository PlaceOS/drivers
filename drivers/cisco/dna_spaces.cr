require "placeos-driver"
require "set"
require "jwt"
require "s2_cells"
require "simple_retry"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/locatable"

class Cisco::DNASpaces < PlaceOS::Driver
  include Interface::Locatable
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Cisco Spaces"
  generic_name :Cisco_Spaces
  uri_base "https://partners.dnaspaces.io"

  default_settings({
    _dna_spaces_activation_key: "provide this and the API / tenant ids will be generated automatically",
    _dna_spaces_api_key:        "X-API-KEY",
    _tenant_id:                 "sfdsfsdgg",
    verify_activation_key:      false,

    # Time before a user location is considered probably too old (in minutes)
    # we have a large time here as DNA spaces only updates when a user moves
    # device exit is used to signal when a device has left the building
    max_location_age: 300,

    floorplan_mappings: {
      location_a4cb0: {
        "level_name" => "optional name",
        "building"   => "zone-GAsXV0nc",
        "level"      => "zone-GAsmleH",
        "offset_x"   => 12.4,
        "offset_y"   => 5.2,
        "map_width"  => 50.3,
        "map_height" => 100.9,
      },
    },

    debug_stream: false,
  })

  @streaming = false
  @last_received = 0_i64
  @stream_active = false

  def on_load
    on_update
  end

  def on_unload
    @channel.close
    @stream_active = false
    update_monitoring_status(running: false)
  end

  @activation_token : String = ""
  @verify_activation_key : Bool = false
  @api_key : String = ""
  @tenant_id : String = ""
  @channel : Channel(String) = Channel(String).new
  @max_location_age : Time::Span = 300.minutes
  @s2_level : Int32 = 21
  @floorplan_mappings : Hash(String, Hash(String, String | Float64)) = Hash(String, Hash(String, String | Float64)).new
  @debug_stream : Bool = false
  @events_received : UInt64 = 0_u64

  def on_update
    @max_location_age = (setting?(UInt32, :max_location_age) || 10).minutes
    @s2_level = setting?(Int32, :s2_level) || 21
    @floorplan_mappings = setting?(Hash(String, Hash(String, String | Float64)), :floorplan_mappings) || @floorplan_mappings
    @debug_stream = setting?(Bool, :debug_stream) || false
    @verify_activation_key = setting?(Bool, :verify_activation_key) || false

    schedule.clear
    schedule.every(30.minutes) { cleanup_caches }
    schedule.every(5.minutes) { update_monitoring_status }
    schedule.in(5.seconds) { update_monitoring_status }

    @activation_token = setting?(String, :dna_spaces_activation_key) || ""
    if @activation_token.empty?
      @api_key = setting(String, :dna_spaces_api_key)
      @tenant_id = setting(String | Int64, :tenant_id).to_s
    else
      @api_key = setting?(String, :dna_spaces_api_key) || ""
      @tenant_id = setting?(String | Int64, :tenant_id).try(&.to_s) || ""

      # Activate the API key using the activation_token
      schedule.in(5.seconds) { activate } if @api_key.empty?
    end

    @description_lock.synchronize do
      if !@streaming && !@api_key.empty?
        @streaming = true
        spawn(same_thread: true) { start_streaming_events }
      end
    end
  end

  @[Security(Level::Support)]
  def activate
    return if @activation_token.empty?

    response = get("/client/v1/partner/partnerPublicKey/")
    raise "failed to obtain partner public key, code #{response.status_code}" unless response.success?

    logger.debug { "public key requested: #{response.body}" }

    payload = NamedTuple(
      status: Bool,
      message: String,
      data: Array(ActivactionPublicKey)).from_json(response.body.not_nil!)

    raise "unexpected failure obtaining partner public key: #{payload[:message]}" unless payload[:status]

    public_key = payload[:data][0].public_key
    payload, header = JWT.decode(@activation_token, public_key, JWT::Algorithm::RS256, @verify_activation_key)
    app_id = payload["appId"].as_s
    ref_id = payload["activationRefId"].as_s
    tenant_id = payload["tenantId"].as_i64.to_s

    response = post("/client/v1/partner/activateOnPremiseApp", headers: {
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{@activation_token}",
    }, body: {
      appId:           app_id,
      activationRefId: ref_id,
    }.to_json)
    raise "failed to obtain API key, code #{response.status_code}\n#{response.body}" unless response.success?

    logger.debug { "application activated: #{response.body}" }

    payload = NamedTuple(
      status: Bool,
      message: String,
      data: NamedTuple(apiKey: String)).from_json(response.body.not_nil!)

    raise "unexpected failure obtaining API key: #{payload[:message]}" unless payload[:status]

    api_key = payload[:data][:apiKey]
    logger.debug { "saving API key: #{tenant_id}, #{api_key}" }

    define_setting(:tenant_id, tenant_id)
    define_setting(:dna_spaces_api_key, api_key)
    define_setting(:dna_spaces_activation_key, "")

    logger.debug { "settings saved! Starting stream" }
    @api_key = api_key
    @tenant_id = tenant_id

    @description_lock.synchronize do
      if !@streaming
        @streaming = true
        spawn(same_thread: true) { start_streaming_events }
      end
    end
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
  @locations : Hash(String, DeviceLocationUpdate | IotTelemetry | WebexTelemetryUpdate) = {} of String => DeviceLocationUpdate | IotTelemetry | WebexTelemetryUpdate
  @loc_lock : Mutex = Mutex.new
  @devices : Hash(String, IotTelemetry | WebexTelemetryUpdate) = {} of String => IotTelemetry | WebexTelemetryUpdate
  @dev_lock : Mutex = Mutex.new

  def locations
    @loc_lock.synchronize { yield @locations }
  end

  def devices
    @dev_lock.synchronize { yield @devices }
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

  @map_details : Hash(String, Dimension) = {} of String => Dimension
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
      map = MapInfo.from_json(response.body.not_nil!).dimension
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
    @streaming = true
    SimpleRetry.try_to(
      base_interval: 2.seconds,
      max_interval: 10.seconds
    ) do
      logger.info { "connecting to event stream" }
      stream_events unless terminated?
    end
  ensure
    @streaming = false
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
          when DeviceLocationUpdate, IotTelemetry, WebexTelemetryUpdate
            device_mac = format_mac(payload.device.mac_address)

            # we want timestamps in seconds
            payload.last_seen = payload.last_seen // 1000

            case payload
            when IotTelemetry
              self[device_mac] = payload
              devices { |dev| dev[device_mac] = payload }

              next unless payload.has_position?
            when WebexTelemetryUpdate
              if webex_obj = devices { |dev| dev[device_mac]? }
                webex_obj = webex_obj.as(WebexTelemetryUpdate)
                webex_obj.device = payload.device
                webex_obj.location = payload.location
                webex_obj.last_seen = payload.last_seen
                webex_obj.telemetries = payload.telemetries
                payload = webex_obj
              else
                @description_lock.synchronize { payload.location.descriptions(@location_descriptions) }
                devices { |dev| dev[device_mac] = payload }
              end
              payload.update_telemetry
              self[device_mac] = payload
            end

            # Keep track of device location
            existing = nil

            # ignore locations where we don't have enough details to put the device on a map
            if payload.map_id.presence
              @location_id_maps[payload.location.location_id] = payload.map_id
            else
              locations = payload.location_mappings.values
              level_id = locations.find { |loc_id| @floorplan_mappings[loc_id]? }

              if level_id && (level_data = @floorplan_mappings[level_id]) && level_data["map_width"]? && level_data["map_height"]?
                # we don't need the map ID as the x, y coordinates are defined by us
                # we do need the map_id for grouping results, so we assign it the level id
                payload.map_id = level_id
              else
                found = false
                payload.location_mappings.values.each do |loc_id|
                  if map_id = @location_id_maps[loc_id]?
                    payload.map_id = map_id
                    found = true
                    break
                  end
                end

                if !found
                  logger.debug { "ignoring device #{device_mac} location as map_id is empty, location id #{payload.location.location_id}, visit #{payload.visit_id}" }
                  next
                end
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
        @stream_active = false
        logger.warn { "failed to connect to firehose api #{response.status_code}" }
        raise "failed to connect to firehose api #{response.status_code}"
      end

      @stream_active = true

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
            @last_received = Time.utc.to_unix_ms
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
    @stream_active = false
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
          next if location.is_a?(WebexTelemetryUpdate)
          if location.last_seen > location_max_age
            # we update the mac_address to a formatted version
            location.device.mac_address = mac
            location
          end
        end
      }.sort! { |a, b|
        b.last_seen <=> a.last_seen
      }.map { |location|
        lat = location.latitude
        lon = location.longitude

        loc = {
          "location"         => "wireless",
          "coordinates_from" => "top-left",
          "x"                => location.x_pos,
          "y"                => location.y_pos,
          "lon"              => lon,
          "lat"              => lat,
          "s2_cell_id"       => S2Cells.at(lat, lon).parent(@s2_level).to_token,
          "mac"              => location.device.mac_address,
          "variance"         => location.unc,
          "last_seen"        => location.last_seen,
          "dna_floor_id"     => location.map_id,
          "ssid"             => location.ssid,
          "manufacturer"     => location.device.manufacturer,
          "os"               => location.device.os,
        }

        map_width = 0.0
        map_height = 0.0
        offset_x = 0.0
        offset_y = 0.0

        # Add our zone IDs to the response
        location.location_mappings.each_value do |location_id|
          if level_data = @floorplan_mappings[location_id]?
            level_data.each do |key, value|
              case key
              when "offset_x"
                offset_x = value.as(Float64)
                loc["x"] = location.x_pos - offset_x
              when "offset_y"
                offset_y = value.as(Float64)
                loc["y"] = location.y_pos - offset_y
              when "map_width"
                map_width = value.as(Float64)
              when "map_height"
                map_height = value.as(Float64)
              else
                loc[key] = value
              end
            end
            break
          end
        end

        # Add map information to the response
        if map_width > 0.0 && map_height > 0.0
          loc["map_width"] = map_width
          loc["map_height"] = map_height
        elsif map_size = get_map_details(location.map_id)
          loc["map_width"] = map_width > 0.0 ? map_width : (map_size.length - offset_x)
          loc["map_height"] = map_height > 0.0 ? map_height : (map_size.width - offset_y)
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
    adjustments = {} of String => Tuple(Float64, Float64, Float64, Float64)
    @floorplan_mappings.each do |floor_id, data|
      if data.values.includes?(zone_id)
        floors << floor_id
        offset_x = (data["offset_x"]? || 0.0).as(Float64)
        offset_y = (data["offset_y"]? || 0.0).as(Float64)
        map_width = (data["map_width"]? || -1.0).as(Float64)
        map_height = (data["map_height"]? || -1.0).as(Float64)
        adjustments[floor_id] = {offset_x, offset_y, map_width, map_height}
      end
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
      offset_x = 0.0
      offset_y = 0.0

      # any adjustments required for these locations?
      locations.first.location_mappings.each_value do |location_id|
        if level_data = adjustments[location_id]?
          offset_x, offset_y, map_width, map_height = level_data
          break
        end
      end

      if map_width == -1.0 || map_height == -1.0
        if map_size = get_map_details(map_id)
          map_width = map_width > -1.0 ? map_width : (map_size.length - offset_x)
          map_height = map_height > -1.0 ? map_height : (map_size.width - offset_y)
        end
      end

      locations.compact_map do |loc|
        next if loc.is_a?(WebexTelemetryUpdate)
        lat = loc.latitude
        lon = loc.longitude

        {
          location:         :wireless,
          coordinates_from: "top-left",
          x:                loc.x_pos - offset_x,
          y:                loc.y_pos - offset_y,
          lon:              lon,
          lat:              lat,
          s2_cell_id:       S2Cells.at(lat, lon).parent(@s2_level).to_token,
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

  # This provides the DNA Spaces dashboard with stream consumption status
  @[Security(PlaceOS::Driver::Level::Administrator)]
  def update_monitoring_status(running : Bool = true) : Nil
    response = put("/api/partners/v1/monitoring/status", headers: {
      "Content-Type" => "application/json",
      "X-API-KEY"    => @api_key,
    }, body: {
      data: {
        overallStatus: {
          status:  running ? "up" : "down",
          notices: [] of Nil,
        },
        instanceDetails: {
          ipAddress:  "",
          instanceId: module_id,
        },
        cloudFirehose: {
          status:       @stream_active ? "connected" : "disconnected",
          lastReceived: @last_received,
        },
        localFirehose: {
          status:       "disconnected",
          lastReceived: 0,
        },
        subsystems: [] of Nil,
      },
    }.to_json)
    raise "failed to update status, code #{response.status_code}\n#{response.body}" unless response.success?
  end
end

require "./dna_spaces/events"
require "./dna_spaces/sensor_interface"
