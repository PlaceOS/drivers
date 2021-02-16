module Cisco; end

module Cisco::Meraki; end

require "uri"
require "json"
require "s2_cells"
require "link-header"
require "./scanning_api"
require "placeos-driver/interface/locatable"

class Cisco::Meraki::Dashboard < PlaceOS::Driver
  include Interface::Locatable

  # Discovery Information
  descriptive_name "Cisco Meraki Dashboard"
  generic_name :Dashboard
  uri_base "https://api.meraki.com"
  description %(
    for more information visit:
      * Dashboard API: https://documentation.meraki.com/zGeneral_Administration/Other_Topics/The_Cisco_Meraki_Dashboard_API
      * Scanning API: https://developer.cisco.com/meraki/scanning-api/#!introduction/scanning-api

    NOTE:: API Call volume is rate limited to 5 calls per second per organization
  )

  default_settings({
    meraki_validator: "configure if scanning API is enabled",
    meraki_secret:    "configure if scanning API is enabled",
    meraki_api_key:   "configure for the dashboard API",

    # We will always accept a reading with a confidence lower than this
    acceptable_confidence: 5.0,

    # Max Uncertainty in meters - we don't accept positions that are less certain
    maximum_uncertainty: 25.0,

    # can we use the meraki dashboard API for user lookups
    default_network_id: "network_id",

    # Max requests a second made to the dashboard
    rate_limit: 4,

    # Area index each point on a floor lands on
    # 21 == ~4 meters squared, which given wifi variance is good enough for tracing
    # S2 cell levels: https://s2geometry.io/resources/s2cell_statistics.html
    s2_level:      21,
    debug_webhook: false,

    # Level mappings, level name for human readability
    floorplan_mappings: {
      "g_727894289773756672" => {
        "building":   "zone-12345",
        "level":      "zone-123456",
        "level_name": "BUILDING - L1",
      },
    },

    # Time before a user location is considered probably too old
    max_location_age: 10,

    # Ignore certain usernames from the dashboard
    ignore_usernames: ["host/"],

    # Enable / Disable dashboard username lookup completely
    disable_username_lookup: false,
  })

  def on_load
    # We want to store our user => mac_address mappings in redis
    @user_mac_mappings = PlaceOS::Driver::RedisStorage.new(module_id, "user_macs")
    spawn { rate_limiter }
    on_update
  end

  @scanning_validator : String = ""
  @scanning_secret : String = ""
  @api_key : String = ""

  @acceptable_confidence : Float64 = 5.0
  @maximum_uncertainty : Float64 = 25.0

  @time_multiplier : Float64 = 0.0
  @confidence_multiplier : Float64 = 0.0
  @max_location_age : Time::Span = 6.minutes
  @drift_location_age : Time::Span = 4.minutes
  @confidence_time : Time::Span = 2.minutes

  @rate_limit : Int32 = 4
  @channel : Channel(Nil) = Channel(Nil).new(1)
  @queue_lock : Mutex = Mutex.new
  @queue_size = 0
  @wait_time : Time::Span = 300.milliseconds

  @storage_lock : Mutex = Mutex.new
  @user_mac_mappings : PlaceOS::Driver::RedisStorage? = nil
  @default_network : String = ""
  @floorplan_mappings : Hash(String, Hash(String, String | Float64)) = Hash(String, Hash(String, String | Float64)).new
  @floorplan_sizes = {} of String => FloorPlan

  @s2_level : Int32 = 21
  @debug_webhook : Bool = false
  @debug_payload : Bool = false
  @ignore_usernames : Array(String) = [] of String

  def on_update
    @scanning_validator = setting?(String, :meraki_validator) || ""
    @scanning_secret = setting?(String, :meraki_secret) || ""
    @api_key = setting?(String, :meraki_api_key) || ""

    @rate_limit = setting?(Int32, :rate_limit) || 4
    @wait_time = 1.second / @rate_limit

    @default_network = setting?(String, :default_network_id) || ""

    @acceptable_confidence = setting?(Float64, :acceptable_confidence) || 5.0
    @maximum_uncertainty = setting?(Float64, :maximum_uncertainty) || 25.0

    @max_location_age = (setting?(UInt32, :max_location_age) || 6).minutes
    # Age we keep a confident value (without drifting towards less confidence)
    @confidence_time = @max_location_age / 3
    # Age at which we discard a drifting value (accepting a less confident value)
    @drift_location_age = @max_location_age - @confidence_time

    # How much confidence do we have in this new value, relative to an old confident value
    @time_multiplier = 1.0_f64 / (@drift_location_age.to_i - @confidence_time.to_i).to_f64
    @confidence_multiplier = 1.0_f64 / (@maximum_uncertainty.to_i - @acceptable_confidence.to_i).to_f64

    @floorplan_mappings = setting?(Hash(String, Hash(String, String | Float64)), :floorplan_mappings) || @floorplan_mappings

    @s2_level = setting?(Int32, :s2_level) || 21
    @debug_webhook = setting?(Bool, :debug_webhook) || false
    @debug_payload = setting?(Bool, :debug_payload) || false

    @ignore_usernames = setting?(Array(String), :ignore_usernames) || [] of String
    disable_username_lookup = setting?(Bool, :disable_username_lookup) || false

    schedule.clear
    if @default_network.presence
      schedule.every(2.minutes) { map_users_to_macs } unless disable_username_lookup
      schedule.every(29.minutes, immediate: true) { sync_floorplan_sizes }
    end
    schedule.every(30.minutes) { cleanup_caches }
  end

  protected def user_mac_mappings
    @storage_lock.synchronize {
      yield @user_mac_mappings.not_nil!
    }
  end

  # Perform fetch with the required API request limits in place
  @[Security(PlaceOS::Driver::Level::Support)]
  def fetch(location : String)
    req(location) { |response| response.body }
  end

  protected def req(location : String)
    if (@wait_time * @queue_size) > 10.seconds
      raise "wait time would be exceeded for API request, #{@queue_size} requests already queued"
    end

    @queue_lock.synchronize { @queue_size += 1 }
    @channel.receive
    @queue_lock.synchronize { @queue_size -= 1 }

    headers = HTTP::Headers{
      "X-Cisco-Meraki-API-Key" => @api_key,
      "Content-Type"           => "application/json",
      "Accept"                 => "application/json",
      "User-Agent"             => "PlaceOS/2.0 PlaceTechnology",
    }

    uri = URI.parse(location)
    response = if uri.host.nil?
                 get(location, headers: headers)
               else
                 HTTP::Client.get(location, headers: headers)
               end

    if response.success?
      yield response
    elsif response.status.found?
      # Meraki might return a `302` on GET requests
      response = HTTP::Client.get(response.headers["Location"], headers: headers)
      if response.success?
        yield response
      else
        raise "request #{location} failed with status: #{response.status_code}"
      end
    else
      raise "request #{location} failed with status: #{response.status_code}"
    end
  end

  EMPTY_HEADERS    = {} of String => String
  SUCCESS_RESPONSE = {HTTP::Status::OK, EMPTY_HEADERS, nil}

  struct Lookup
    include JSON::Serializable

    property time : Time
    property mac : String

    def initialize(@time, @mac)
    end
  end

  # MAC Address => Location
  @locations : Hash(String, Location) = {} of String => Location
  @ip_lookup : Hash(String, Lookup) = {} of String => Lookup

  def lookup_ip(address : String)
    @ip_lookup[address.downcase]?
  end

  def locate_mac(address : String)
    @locations[format_mac(address)]?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def inspect_state
    logger.debug {
      "IP Mappings: #{@ip_lookup.keys}\n\nMAC Locations: #{@locations.keys}\n\nClient Details: #{@client_details.keys}"
    }
    {ip_mappings: @ip_lookup.size, tracking: @locations.size, client_details: @client_details.size}
  end

  # Returns the list of users who can be located
  @[Security(PlaceOS::Driver::Level::Support)]
  def locateable
    too_old = location_max_age = @max_location_age.ago
    @client_details.compact_map do |mac, client|
      location = @locations[mac]?
      client.user if location && ((location.time > too_old) || (client.time_added > too_old))
    end
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def poll_clients(network_id : String? = nil, timespan : UInt32 = 900_u32)
    network_id = network_id.presence || @default_network

    clients = [] of Client
    next_page = "/api/v1/networks/#{network_id}/clients?perPage=1000&timespan=#{timespan}"

    loop do
      break unless next_page

      next_page = req(next_page) do |response|
        clients.concat Array(Client).from_json(response.body)
        LinkHeader.new(response)["next"]?
      end
    end

    clients
  end

  @client_details : Hash(String, Client) = {} of String => Client

  @[Security(PlaceOS::Driver::Level::Support)]
  def map_users_to_macs(network_id : String? = nil)
    network_id = network_id.presence || @default_network

    logger.debug { "mapping users to device MACs" }
    clients = poll_clients(network_id)

    new_devices = 0
    updated_dev = 0
    now = Time.utc

    logger.debug { "mapping found #{clients.size} devices" }

    user_mac_mappings do |storage|
      clients.each do |client|
        # So we can merge additional details into device location responses
        user_mac = format_mac(client.mac)
        client.time_added = now

        user_id = client.user

        if user_id
          @ignore_usernames.each do |name|
            if user_id.starts_with?(name)
              client.user = user_id = nil
              break
            end
          end
        end

        # Attempt to lookup username via learning
        if user_id.nil?
          if known_id = storage[user_mac]?
            client.user = known_id
          end
        end

        @client_details[user_mac] = client
        next unless user_id

        was_update, was_new = map_user_mac(user_mac, user_id, storage)
        updated_dev += 1 if was_update
        new_devices += 1 if was_new
      end
    end

    logger.debug { "mapping assigned #{new_devices} new devices, #{updated_dev} user updated" }
    nil
  end

  protected def map_user_mac(user_mac, user_id, storage)
    updated_dev = false
    new_devices = false
    user_id = format_username(user_id)

    # Check if mac mapping already exists
    existing_user = storage[user_mac]?
    return {false, false} if existing_user == user_id

    # Remove any pervious mappings
    if existing_user
      updated_dev = true
      if user_macs = storage[existing_user]?
        macs = Array(String).from_json(user_macs)
        macs.delete(user_mac)
        storage[existing_user] = macs.to_json
      end
    else
      new_devices = true
    end

    # Update the user mappings
    storage[user_mac] = user_id
    macs = if user_macs = storage[user_id]?
             tmp_macs = Array(String).from_json(user_macs)
             tmp_macs.unshift(user_mac)
             tmp_macs.uniq!
             tmp_macs[0...9]
           else
             [user_mac]
           end
    storage[user_id] = macs

    {updated_dev, new_devices}
  end

  def format_username(user : String)
    if user.includes? "@"
      user = user.split("@")[0]
    elsif user.includes? "\\"
      user = user.split("\\")[1]
    end
    user.downcase
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    username = format_username(username.presence || email.presence.not_nil!)
    if macs = user_mac_mappings { |s| s[username]? }
      Array(String).from_json(macs)
    else
      [] of String
    end
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    lookup = format_mac(mac_address)
    if user = user_mac_mappings { |s| s[lookup]? }
      {
        location:    "wireless",
        assigned_to: user,
        mac_address: lookup,
      }
    end
  end

  # returns locations based on most recently seen
  # versus most accurate location
  def locate_user(email : String? = nil, username : String? = nil)
    username = format_username(username.presence || email.presence.not_nil!)

    if macs = user_mac_mappings { |s| s[username]? }
      location_max_age = @max_location_age.ago

      Array(String).from_json(macs).compact_map { |mac|
        if location = locate_mac(mac)
          client = @client_details[mac]?

          # We set these here to speed up processing
          location.client = client
          location.mac = mac

          if client && client.time_added > location_max_age
            location
          elsif location.time > location_max_age
            location
          end
        end
      }.sort { |a, b|
        b.time <=> a.time
      }.map { |location|
        lat = location.lat
        lon = location.lng

        loc = {
          "location"          => "wireless",
          "coordinates_from"  => "bottom-left",
          "x"                 => location.x,
          "y"                 => location.y,
          "lon"               => lon,
          "lat"               => lat,
          "s2_cell_id"        => lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
          "mac"               => location.mac,
          "variance"          => location.variance,
          "last_seen"         => location.time.to_unix,
          "meraki_floor_id"   => location.floor_plan_id,
          "meraki_floor_name" => location.floor_plan_name,
        }

        # Add our zone IDs to the response
        if level_data = @floorplan_mappings[location.floor_plan_id]?
          level_data.each { |k, v| loc[k] = v }
        end

        # Add meraki map information to the response
        if map_size = @floorplan_sizes[location.floor_plan_id]?
          loc["map_width"] = map_size.width
          loc["map_height"] = map_size.height
        end

        # Add additional client information if it's available
        if client = location.client
          loc["manufacturer"] = client.manufacturer if client.manufacturer
          loc["os"] = client.os if client.os
          loc["ssid"] = client.ssid if client.ssid
        end

        loc
      }
    else
      [] of Nil
    end
  end

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
    oldest_location = @max_location_age.ago
    matching = @locations.compact_map do |mac, loc|
      # We set this here to speed up processing
      client = @client_details[mac]?
      loc.client = client

      if loc.time < oldest_location
        if client
          if client.time_added < oldest_location
            too_old += 1
            next
          end
        else
          too_old += 1
          next
        end
      end
      if !floors.includes?(loc.floor_plan_id)
        wrong_floor += 1
        next
      end
      # ensure the formatted mac is being used
      loc.mac = mac
      loc
    end

    logger.debug { "found #{matching.size} matching devices\nchecked #{checking_count} locations, #{wrong_floor} were on the wrong floor, #{too_old} were too old" }

    # Build the payload on the matching locations
    matching.group_by(&.floor_plan_id).flat_map { |floor_id, locations|
      map_width = -1.0
      map_height = -1.0

      if map_size = @floorplan_sizes[floor_id]?
        map_width = map_size.width
        map_height = map_size.height
      elsif mappings = @floorplan_mappings[floor_id]?
        map_width = (mappings["width"]? || map_width).as(Float64)
        map_height = (mappings["height"]? || map_width).as(Float64)
      end

      locations.map do |loc|
        lat = loc.lat
        lon = loc.lng

        # Add additional client information if it's available
        if client = @client_details[loc.mac]?
          manufacturer = client.manufacturer
          os = client.os
          ssid = client.ssid
        end

        {
          location:         :wireless,
          coordinates_from: "bottom-left",
          x:                loc.x,
          y:                loc.y,
          lon:              lon,
          lat:              lat,
          s2_cell_id:       lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
          mac:              loc.mac,
          variance:         loc.variance,
          last_seen:        loc.time.to_unix,
          map_width:        map_width,
          map_height:       map_height,
          manufacturer:     manufacturer,
          os:               os,
          ssid:             ssid,
        }
      end
    }
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def cleanup_caches : Nil
    logger.debug { "removing IP and location data that is over 30 minutes old" }

    # IP => MAC mappings
    old = 30.minutes.ago
    remove_keys = [] of String
    @ip_lookup.each { |ip, lookup| remove_keys << ip if lookup.time < old }
    remove_keys.each { |ip| @ip_lookup.delete(ip) }
    logger.debug { "removed #{remove_keys.size} IP => MAC mappings" }

    # IP => Username mappings
    remove_keys.clear
    @ip_usernames.each { |ip, lookup| remove_keys << ip if lookup.time < old }
    remove_keys.each { |ip| @ip_usernames.delete(ip) }
    logger.debug { "removed #{remove_keys.size} IP => Username mappings" }

    # Client details
    remove_keys.clear
    @client_details.each { |mac, client| remove_keys << mac if client.time_added < old }
    remove_keys.each { |mac| @client_details.delete(mac) }
    logger.debug { "removed #{remove_keys.size} client details" }

    # MACs
    remove_keys.clear
    @locations.each do |mac, location|
      if location.time < old
        if client = @client_details[mac]?
          remove_keys << mac if client.time_added < old
        else
          remove_keys << mac
        end
      end
    end
    remove_keys.each { |mac| @locations.delete(mac) }
    logger.debug { "removed #{remove_keys.size} MACs" }
  end

  class FloorPlan
    include JSON::Serializable

    @[JSON::Field(key: "floorPlanId")]
    property id : String
    property width : Float64
    property height : Float64

    # This is useful for when we have to map meraki IDs to our zones
    property name : String?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def sync_floorplan_sizes(network_id : String? = nil)
    network_id = network_id.presence || @default_network
    logger.debug { "syncing floor plan sizes for network #{network_id}" }

    floor_plans = {} of String => FloorPlan

    req("/api/v1/networks/#{network_id}/floorPlans") { |response|
      Array(FloorPlan).from_json(response.body).each do |plan|
        floor_plans[plan.id] = plan
      end
      nil
    }

    @floorplan_sizes = floor_plans
  end

  # Webhook endpoint for scanning API, expects version 3
  def scanning_api(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "scanning API received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_payload

    # Return the scanning API validator code on a GET request
    return {HTTP::Status::OK.to_i, EMPTY_HEADERS, @scanning_validator} if method == "GET"

    # Check the version matches
    if !body.starts_with?(%({"version":"3.0"))
      logger.warn { "unknown scanning API message received:\n#{body[0..96]}" }
      return SUCCESS_RESPONSE
    end

    locations_updated = 0

    # Parse the data posted
    begin
      seen = DevicesSeen.from_json(body)
      logger.debug { "parsed meraki payload" }

      # We're only interested in Wifi at the moment
      if seen.message_type != "WiFi"
        logger.debug { "ignoring message type: #{seen.message_type}" }
        return SUCCESS_RESPONSE
      end

      # Check the secret matches
      raise "secret mismatch, sent: #{seen.secret}" unless seen.secret == @scanning_secret

      # Extract coordinate data against the MAC address and save IP address mappings
      observations = seen.data.observations.reject(&.locations.empty?)

      ignore_older = @max_location_age.ago.in Time::Location::UTC
      drift_older = @drift_location_age.ago.in Time::Location::UTC
      current_time = Time.utc
      current_time_unix = current_time.to_unix

      observations.each do |observation|
        client_mac = format_mac(observation.client_mac)
        existing = @locations[client_mac]?

        logger.debug { "parsing new observation for #{client_mac}" } if @debug_webhook
        location = parse(existing, ignore_older, drift_older, current_time_unix, observation.latest_record.time, observation.locations)
        if location
          @locations[client_mac] = location
          locations_updated += 1
        end
        update_ipv4(observation.ipv4, client_mac, current_time)
        update_ipv6(observation.ipv6.try(&.downcase), client_mac, current_time)
      end
    rescue e
      logger.error { "failed to parse meraki scanning API payload\n#{e.inspect_with_backtrace}" }
      logger.debug { "failed payload body was\n#{body}" }
    end

    logger.debug { "updated #{locations_updated} locations" }

    # Return a 200 response
    SUCCESS_RESPONSE
  end

  protected def parse(existing, ignore_older, drift_older, current_time, latest_raw, locations_raw) : Location?
    # deal with times in a relative way
    adjust_by = (current_time - latest_raw.to_unix).seconds

    # existing.time is our ajusted time
    if existing_time = existing.try &.time
      existing = nil if existing_time < ignore_older
    end

    # remove locations that don't have an x,y or very uncertain or very old
    locations = locations_raw.reject do |loc|
      loc.time = loc.time + adjust_by
      loc.get_x.nil? || loc.variance > @maximum_uncertainty
    end

    if locations.empty?
      logger.debug {
        if locations_raw.empty?
          "ignored as no location data provided"
        else
          "ignored as no location in observation met minimum requirements, had coordinates: #{!!locations_raw[0].get_x}, uncertainty: #{locations_raw[0].variance}"
        end
      } if @debug_webhook
      return existing
    end

    # ensure oldest -> newest (we adjusted these already)
    locations = locations.sort { |a, b| a.time <=> b.time }

    # estimate the location given the current observations
    location = existing || locations.shift
    locations.each do |new_loc|
      next unless new_loc.time >= location.time

      # If acceptable then this is newer
      if new_loc.variance < @acceptable_confidence
        location = new_loc
        next
      end

      # if more accurate and newer then we'll take this
      if new_loc.variance < location.variance
        location = new_loc
        next
      end

      # should we drift the older location towards a less accurate newer location
      if location.time < drift_older
        # has the floor changed, we should probably accept the newer less accurate location
        if location.floor_plan_id != new_loc.floor_plan_id
          location = new_loc
          next
        end

        new_uncertainty = new_loc.variance
        old_uncertainty = location.variance

        confidence_factor = 1.0 - (@confidence_multiplier * (new_uncertainty - @acceptable_confidence))
        confidence_factor = 0.0 if confidence_factor < 0

        time_diff = new_loc.time.to_unix - location.time.to_unix
        time_factor = @time_multiplier * (time_diff - @confidence_time.to_i).to_f
        time_factor = 0.0 if time_factor < 0

        # Average of the confidence factors
        average_multiplier = (confidence_factor + time_factor) / 2.0

        new_x = new_loc.x!
        new_y = new_loc.y!
        old_x = location.x!
        old_y = location.y!

        # 7.5 =   5   + ((  10  -  5   ) * 0.5)
        new_x = old_x + ((new_x - old_x) * average_multiplier)
        new_y = old_y + ((new_y - old_y) * average_multiplier)
        new_uncertainty = old_uncertainty + ((new_uncertainty - old_uncertainty) * average_multiplier)

        new_loc.x = new_x
        new_loc.y = new_y
        new_loc.variance = new_uncertainty
        location = new_loc
      end
    end

    location
  end

  protected def update_ipv4(ipv4, client_mac, current_time)
    return unless ipv4

    lookup = @ip_lookup[ipv4]? || Lookup.new(current_time, client_mac)
    lookup.time = current_time
    lookup.mac = client_mac
    @ip_lookup[ipv4] = lookup

    if lookup = @ip_usernames[ipv4]?
      username = lookup.mac
      user_mac_mappings { |storage| map_user_mac(client_mac, username, storage) }
    end
  end

  protected def update_ipv6(ipv6, client_mac, current_time)
    return unless ipv6

    lookup = @ip_lookup[ipv6]? || Lookup.new(current_time, client_mac)
    lookup.time = current_time
    lookup.mac = client_mac
    @ip_lookup[ipv6] = lookup

    if lookup = @ip_usernames[ipv6]?
      username = lookup.mac
      user_mac_mappings { |storage| map_user_mac(client_mac, username, storage) }
    end
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  protected def rate_limiter
    loop do
      begin
        @channel.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep @wait_time
      end
    end
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter }
  end

  # ip => {username, time}
  @ip_usernames : Hash(String, Lookup) = {} of String => Lookup

  @[Security(PlaceOS::Driver::Level::Administrator)]
  def ip_username_mappings(ip_map : Array(Tuple(String, String, String, String?))) : Nil
    now = Time.utc
    user_mac_mappings do |storage|
      ip_map.each do |(ip, username, domain, hostname)|
        username = format_username(username)
        @ip_usernames[ip] = Lookup.new(now, username)

        if lookup = @ip_lookup[ip]?
          map_user_mac(lookup.mac, username, storage)
        end
      end
    end
  end
end
