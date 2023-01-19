require "placeos-driver"
require "json"
require "s2_cells"
require "./mqtt_models"
require "./scanning_api"
require "../../place/area_polygon"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/locatable"

class Cisco::Meraki::Locations < PlaceOS::Driver
  include Interface::Locatable
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Meraki Location Service"
  generic_name :MerakiLocations

  description %(requires meraki dashboard driver for API calls)

  accessor dashboard : Dashboard_1
  accessor staff_api : StaffAPI_1
  accessor area_manager : AreaManagement_1

  default_settings({
    # We will always accept a reading with a confidence lower than this
    acceptable_confidence: 5.0,

    # Max Uncertainty in meters - we don't accept positions that are less certain
    maximum_uncertainty: 25.0,

    # For confident yet inaccurate location data/maps. If a location's variance is below this threshold, increase it to this value.
    # 0.0 disables the override
    override_min_variance: 0.0,

    # Optionally only store locations for devices whose "os" property matches this regex string.
    regex_filter_device_os: nil,

    # can we use the meraki dashboard API for user lookups
    default_network_id: "network_id",

    # Area index each point on a floor lands on
    # 21 == ~4 meters squared, which given wifi variance is good enough for tracing
    # S2 cell levels: https://s2geometry.io/resources/s2cell_statistics.html
    s2_level:      21,
    debug_payload: false,
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

    # Where desks have no occupancy
    return_empty_spaces: true,

    # wired desks mappings
    wired_desks: [
      {
        serial:   "switch-serial-number",
        level_id: "zone-1234",
        ports:    {
          11 => "desk-1234",
          12 => "desk-5678",
        },
      },
    ],
  })

  alias WiredDesks = Hash(String, Hash(Int32, String))

  def on_load
    # We want to store our user => mac_address mappings in redis
    @user_mac_mappings = PlaceOS::Driver::RedisStorage.new(module_id, "user_macs")
    on_update
  end

  @acceptable_confidence : Float64 = 5.0
  @maximum_uncertainty : Float64 = 25.0
  @override_min_variance : Float64 = 0.0
  @regex_filter_device_os : String? = nil
  getter building_zone : String = "searching..."

  @time_multiplier : Float64 = 0.0
  @confidence_multiplier : Float64 = 0.0
  @max_location_age : Time::Span = 6.minutes
  @drift_location_age : Time::Span = 4.minutes
  @confidence_time : Time::Span = 2.minutes

  @storage_lock : Mutex = Mutex.new
  @user_mac_mappings : PlaceOS::Driver::RedisStorage? = nil
  @default_network : String = ""
  @floorplan_mappings : Hash(String, Hash(String, String | Float64)) = Hash(String, Hash(String, String | Float64)).new
  @floorplan_sizes = {} of String => FloorPlan
  @network_devices = {} of String => NetworkDevice

  @s2_level : Int32 = 21
  @ignore_usernames : Array(String) = [] of String
  @return_empty_spaces : Bool = true

  @debug_payload : Bool = false
  @debug_webhook : Bool = false

  def on_update
    @default_network = setting?(String, :default_network_id) || ""
    @return_empty_spaces = setting?(Bool, :return_empty_spaces) || false

    @acceptable_confidence = setting?(Float64, :acceptable_confidence) || 5.0
    @maximum_uncertainty = setting?(Float64, :maximum_uncertainty) || 25.0
    @override_min_variance = setting?(Float64, :override_min_variance) || 0.0
    @regex_filter_device_os = setting?(String, :regex_filter_device_os)

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
    @debug_payload = setting?(Bool, :debug_payload) || false
    @debug_webhook = setting?(Bool, :debug_webhook) || false
    @ignore_usernames = setting?(Array(String), :ignore_usernames) || [] of String
    disable_username_lookup = setting?(Bool, :disable_username_lookup) || false

    schedule.clear

    # Wired desk data
    init_wired_port_mappings

    if @default_network.presence
      schedule.every(59.seconds) { update_sensor_cache }
      schedule.every(2.minutes) { map_users_to_macs } unless disable_username_lookup
      schedule.every(29.minutes) { sync_floorplan_sizes }

      schedule.in(30.milliseconds) do
        sync_floorplan_sizes
        update_sensor_cache
      end
    end
    schedule.every(30.minutes) { cleanup_caches }

    subscriptions.clear
    if @default_network.presence
      dashboard.subscribe(@default_network) do |_subscription, new_value|
        # values are always raw JSON strings
        parse_new_locations(new_value)
      end
    end

    zones = config.control_system.not_nil!.zones
    spawn(same_thread: true) { find_building(zones) }

    # Grab desk data from the MQTT connection
    if system.exists? :MerakiMQTT
      mqtt_module = system[:MerakiMQTT]
      mqtt_module.subscribe(:floor_lookup) do |_sub, new_value|
        next if new_value.nil? || new_value == "null"
        @floor_lookup = Hash(String, FloorMapping).from_json(new_value)
        update_desk_mappings unless @zone_lookup.empty?
      end
      mqtt_module.subscribe(:zone_lookup) do |_sub, new_value|
        next if new_value.nil? || new_value == "null"
        @zone_lookup = Hash(String, Array(String)).from_json(new_value)
        update_desk_mappings unless @floor_lookup.empty?
      end
      schedule.every(10.minutes) { update_desk_mappings }
      mqtt_module.subscribe(:camera_updated) do |_sub, new_value|
        next if new_value.nil? || new_value == "null"
        _time, camera_serial = Tuple(Int64, String).from_json(new_value)

        if @desk_mappings.has_key? camera_serial
          check_camera_status(mqtt_module, camera_serial)
        end
      end
    end
  end

  # grab building zone from the current system
  protected def find_building(zones : Array(String)) : Nil
    zones.each do |zone_id|
      zone = ZoneDetails.from_json staff_api.zone(zone_id).get.to_json
      if zone.tags.includes?("building")
        @building_zone = zone.id
        break
      end
    end
    raise "no building zone found in System" unless @building_zone
  rescue error
    logger.warn(exception: error) { "error looking up building zone" }
    schedule.in(5.seconds) { find_building(zones) }
  end

  protected def check_camera_status(mqtt_module, camera_serial)
    detected_desks = mqtt_module.status(DetectedDesks, "camera_#{camera_serial}_desks")
    desk_details[camera_serial] = detected_desks
    average_results(camera_serial, detected_desks)
    if lux_level = mqtt_module.status?(Float64, "camera_#{camera_serial}_lux")
      lux[camera_serial] = lux_level
    end
  end

  # serial => desks detected
  getter desk_details : Hash(String, DetectedDesks) = {} of String => DetectedDesks

  # serial => lux
  getter lux : Hash(String, Float64) = {} of String => Float64

  protected def user_mac_mappings
    @storage_lock.synchronize {
      yield @user_mac_mappings.not_nil!
    }
  end

  protected def req(location : String)
    response = dashboard.fetch(location).get.as_s
    begin
      yield response
    rescue error
      logger.debug(exception: error) { "processing failed for #{location} with response: #{response}" }
      raise error
    end
  end

  protected def req_all(location : String)
    dashboard.fetch_all(location).get.as_a.each { |resp| yield resp.as_s }
  end

  struct Lookup
    include JSON::Serializable

    property time : Time
    property mac : String

    def initialize(@time, @mac)
    end
  end

  # MAC Address => Location
  @locations : Hash(String, DeviceLocation) = {} of String => DeviceLocation
  @ip_lookup : Hash(String, Lookup) = {} of String => Lookup

  def lookup_ip(address : String)
    @ip_lookup[address.downcase]?
  end

  def locate_mac(address : String)
    @locations[format_mac(address)]?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def inspect_foorplans
    @floorplan_sizes
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def inspect_network_devices
    @network_devices
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
    too_old = @max_location_age.ago
    @client_details.compact_map do |mac, client|
      location = @locations[mac]?
      client.user if location && ((location.time > too_old) || (client.time_added > too_old))
    end
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def poll_clients(
    network_id : String? = nil,
    timespan : UInt32 = 900_u32,
    connection : ConnectionType? = nil,
    device_serial : String? = nil
  )
    network_id = network_id.presence || @default_network
    Array(Client).from_json dashboard.poll_clients(network_id, timespan, connection, device_serial).get.to_json
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

        # Store the mac to hostname lookups to help with learning
        if hostname = client.description
          @mac_hostnames[user_mac] = hostname
        end

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
    if macs = user_mac_mappings(&.[username]?)
      Array(String).from_json(macs)
    else
      [] of String
    end
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    lookup = format_mac(mac_address)
    if user = user_mac_mappings(&.[lookup]?)
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

    if macs = user_mac_mappings(&.[username]?)
      location_max_age = @max_location_age.ago

      Array(String).from_json(macs).compact_map { |mac|
        if location = locate_mac(mac)
          client = @client_details[mac]?

          # If a filter is set, then ignore this device unless it matches
          if @regex_filter_device_os
            if client && client.os
              unless /#{@regex_filter_device_os}/.match(client.os.not_nil!)
                logger.debug { "[#{username}] IGNORING #{mac} as OS does not match regex filter" }
                next
              end
            else
              logger.debug { "[#{username}] IGNORING #{mac} as OS is UNKNOWN" }
              next
            end
          end

          # We set these here to speed up processing
          location.client = client
          location.mac = mac

          if client && client.time_added > location_max_age
            location
          elsif location.time > location_max_age
            location
          end
        end
      }.sort! { |a, b|
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
    case location.presence
    when "wireless"
      wireless_locations(zone_id)
    when "desk"
      desk_locs = wired_desk_locations(zone_id)
      cam_locs = desk_locations(zone_id)
      combind = Array(typeof(cam_locs[0]) | typeof(desk_locs[0])).new(cam_locs.size + desk_locs.size)
      combind.concat(desk_locs)
      combind.concat(cam_locs)
    when nil
      wireless_locs = wireless_locations(zone_id)
      desk_locs = wired_desk_locations(zone_id)
      cam_locs = desk_locations(zone_id)
      combind = Array(typeof(wireless_locs[0]) | typeof(cam_locs[0]) | typeof(desk_locs[0])).new(wireless_locs.size + cam_locs.size + desk_locs.size)
      combind.concat(wireless_locs)
      combind.concat(desk_locs)
      combind.concat(cam_locs)
    else
      [] of String
    end
  end

  def wireless_locations(zone_id : String)
    # Find the floors associated with the provided zone id
    floors = [] of String
    @floorplan_mappings.each do |floor_id, data|
      floors << floor_id if data.values.includes?(zone_id)
    end
    logger.debug { "found matching meraki floors: #{floors}" }
    return [] of String if floors.empty?

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

      locations.compact_map do |loc|
        lat = loc.lat
        lon = loc.lng

        # Add additional client information if it's available
        if client = @client_details[loc.mac]?
          manufacturer = client.manufacturer
          os = client.os
          ssid = client.ssid
        end

        # Skip payloads with invalid coordinates
        if (x = loc.x) && (y = loc.y)
          if x.is_a?(Float64) && y.is_a?(Float64)
            if loc.x.as(Float64).nan? || loc.y.as(Float64).nan?
              logger.warn { "ignoring bad location for #{loc.mac}, NaN" }
              next
            end
          else
            logger.warn { "ignoring bad location for #{loc.mac}, unexpected value #{loc.x.inspect}" }
            next
          end
        else
          logger.warn { "ignoring bad location for #{loc.mac}, no coordinates provided" }
          next
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

  @[Security(PlaceOS::Driver::Level::Support)]
  def sync_floorplan_sizes(network_id : String? = nil)
    network_id = network_id.presence || @default_network
    logger.debug { "syncing floor plan sizes for network #{network_id}" }

    floor_plans = {} of String => FloorPlan

    req_all("/api/v1/networks/#{network_id}/floorPlans?perPage=1000") { |response|
      Array(FloorPlan).from_json(response).each do |plan|
        floor_plans[plan.id] = plan
      end
      nil
    }

    @floorplan_sizes = floor_plans

    # mac address => device location
    network_devices = {} of String => NetworkDevice
    cameras = [] of NetworkDevice

    req_all("/api/v1/networks/#{network_id}/devices?perPage=1000") { |response|
      Array(NetworkDevice).from_json(response).each do |device|
        cameras << device if device.firmware.starts_with?("cam")
        next unless device.floor_plan_id
        network_devices[format_mac(device.mac)] = device
      end
      nil
    }

    @network_devices = network_devices
    @cameras = cameras

    {floor_plans, network_devices}
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def camera_analytics(serial : String)
    req("/api/v1/devices/#{serial}/camera/analytics/live") do |response|
      CameraAnalytics.from_json(response)
    end
  end

  alias CamAnalytics = NamedTuple(
    camera: NetworkDevice,
    details: CameraAnalytics,
    building: String?,
    level: String?)

  @camera_analytics = {} of String => CamAnalytics
  @cameras = [] of NetworkDevice

  getter cameras

  def update_sensor_cache
    analytics = {} of String => CamAnalytics
    cameras.each do |cam|
      begin
        mappings = @floorplan_mappings[cam.floor_plan_id]?
        counts = camera_analytics(cam.serial)
        mac = format_mac(cam.mac)
        if mappings
          analytics[mac] = {
            camera:   cam,
            details:  counts,
            building: mappings["building"]?.as(String?),
            level:    mappings["level"]?.as(String?),
          }
        else
          analytics[mac] = {
            camera:   cam,
            details:  counts,
            building: nil.as(String?),
            level:    nil.as(String?),
          }
        end

        counts.zones.each do |area_id, count|
          self["people-#{mac}-#{area_id}"] = count.person
          self["presence-#{mac}-#{area_id}"] = count.person > 0
        end
      rescue error
        logger.debug(exception: error) { "failed to obtain analytics for #{cam.name} (serial: #{cam.serial})" }
      end
    end
    @camera_analytics = analytics
  end

  # Webhook endpoint for scanning API, expects version 3
  def parse_new_locations(payload : String) : Nil
    logger.debug { payload } if @debug_payload

    locations_updated = 0

    # Parse the data posted
    begin
      observations = Array(Observation).from_json(payload)
      logger.debug { "parsed meraki payload" }

      ignore_older = @max_location_age.ago.in Time::Location::UTC
      drift_older = @drift_location_age.ago.in Time::Location::UTC
      current_time = Time.utc

      observations.each do |observation|
        client_mac = format_mac(observation.client_mac)
        existing = @locations[client_mac]?
        logger.debug { "parsing new observation for #{client_mac}" } if @debug_webhook

        # If a filter is set, then ignore this device unless it matches
        if @regex_filter_device_os
          # client.os has more accurate data (observation.os is usually nil for iPhones)
          client = @client_details[format_mac(observation.client_mac)]?
          if client.nil? || /#{@regex_filter_device_os}/.match(client.os || "").nil?
            logger.debug { "FILTERED OUT #{client_mac}: OS \"#{observation.os}\" did not match \"#{@regex_filter_device_os}\"" } if @debug_webhook
            next
          end
        end
        location = parse(existing, ignore_older, drift_older, observation)
        if location
          @locations[client_mac] = location
          locations_updated += 1
        end
        update_ipv4(observation.ipv4, client_mac, current_time)
        update_ipv6(observation.ipv6.try(&.downcase), client_mac, current_time)
      end
    rescue e
      logger.error { "failed to parse meraki scanning API payload\n#{e.inspect_with_backtrace}" }
      logger.debug { "failed payload body was\n#{payload}" }
    end

    logger.debug { "updated #{locations_updated} locations" }
  end

  protected def parse(existing, ignore_older, drift_older, observation) : DeviceLocation?
    locations_raw = observation.locations

    # We'll attempt to return a location based on the nearest WAP
    if locations_raw.empty?
      last_seen = observation.latest_record
      if wap_device = @network_devices[format_mac(last_seen.nearest_ap_mac)]?
        return wap_device.location unless wap_device.location.nil?

        if floor_plan = @floorplan_sizes[wap_device.floor_plan_id.not_nil!]?
          return wap_device.location = DeviceLocation.calculate_location(floor_plan, wap_device, last_seen.time)
        end
      end
      return nil
    end

    # existing.time is our ajusted time
    if existing_time = existing.try &.time
      existing = nil if existing_time < ignore_older
    end

    # remove locations that don't have an x,y or very uncertain or very old
    locations = locations_raw.reject do |loc|
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
        location.variance = @override_min_variance if location.variance < @override_min_variance
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
        new_loc.variance = new_uncertainty < @override_min_variance ? @override_min_variance : new_uncertainty

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

  @[Security(PlaceOS::Driver::Level::Administrator)]
  def mac_address_mappings(username : String, macs : Array(String), domain : String = "")
    username = format_username(username)
    user_mac_mappings do |storage|
      macs.each { |mac| map_user_mac(format_mac(mac), username, storage) }
    end
  end

  # ==========================
  # Wired Port Sensing / desks
  # ==========================

  bind Dashboard_1, :port_update, :port_updated

  # Serial => level + port mappings
  @wired_desks : Hash(String, DeskMappings) = {} of String => DeskMappings

  # level_id => [switch serial numbers]
  @level_serials : Hash(String, Array(String)) = {} of String => Array(String)

  # serial => port => status + mac address?
  @port_status : Hash(String, Hash(Int32, PortStatusResponse)) = {} of String => Hash(Int32, PortStatusResponse)

  # User lookup helpers using device hostnames
  getter mac_hostnames : Hash(String, String) = {} of String => String

  protected def init_wired_port_mappings
    @port_status = Hash(String, Hash(Int32, PortStatusResponse)).new { |h, k| h[k] = {} of Int32 => PortStatusResponse }

    wired_desks = setting?(Array(DeskMappings), :wired_desks) || [] of DeskMappings
    level_serials = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
    desk_mappings = {} of String => DeskMappings
    wired_desks.each do |switch|
      level_serials[switch.level_id] << switch.serial
      desk_mappings[switch.serial] = switch
    end
    @wired_desks = desk_mappings
    @level_serials = level_serials

    spawn(same_thread: true) { get_port_status(@wired_desks.keys) }

    if (serials = @wired_desks.keys) && !serials.empty?
      schedule.in(5.seconds) { get_port_status(serials) }
      schedule.every(5.minutes) { get_port_status(serials) }
    end
  rescue error
    logger.warn(exception: error) { "error initializing wired port mappings" }
  end

  def hostname_ownership(hostname : String, username : String?) : Nil
    macs = @mac_hostnames.compact_map { |(mac, host)| host == hostname ? mac : nil }

    if username && username.presence
      user_mac_mappings { |storage| macs.each { |mac| map_user_mac(mac, username, storage) } }
    else
      # just in case the client doesn't show up again, we don't need to perform lookups
      macs.each { |mac| @mac_hostnames.delete mac }
    end
  end

  # grab all the client data we have (applies to all ports)
  # grab the port information
  # check we have a desk mapping for the port
  # see if we can find the client information for the port
  protected def get_port_status(devices : Iterable(String))
    all_clients = poll_clients(@default_network, connection: :wired)
    devices.each do |serial|
      begin
        ports = @port_status[serial]
        mappings = @wired_desks[serial]

        Array(PortStatusResponse).from_json(dashboard.ports_statuses(serial).get.to_json).each do |port|
          # ensure the port has a desk mapping
          desk_id = mappings.ports[port.port]?
          next unless desk_id

          port.desk_id = desk_id
          port.level_id = mappings.level_id
          port.switch_serial = serial

          if port.status.connected? && (client = all_clients.find { |c| c.recent_device_serial == serial && c.switch_port == port.port })
            port.mac = client.mac
          end

          ports[port.port] = port
        end
      rescue error
        logger.warn(exception: error) { "error querying port statuses for #{serial}" }
      end
    end
  end

  private def port_updated(_subscription, new_value)
    details = WebhookAlert.from_json(new_value)
    logger.debug { "switch #{details.device_serial}, port #{details.port_num} = #{details.alert_type}" }

    serial = details.device_serial
    if mappings = @wired_desks[serial]?
      # query the switch for the port status
      get_port_status({serial})
      area_manager.update_available({mappings.level_id})
    end
  rescue error
    logger.warn(exception: error) { "failed to parse port update\n#{new_value.inspect}" }
  end

  # grabs the wired desk data for a level
  def wired_desk_locations(zone_id : String)
    return_empty_spaces = @return_empty_spaces

    serials = if zone_id == @building_zone
                @level_serials.values.flatten
              else
                @level_serials[zone_id]? || [] of String
              end

    serials.compact_map { |serial|
      ports = @port_status[serial]?
      next unless ports

      ports.map do |(port_num, port)|
        occupied = port.status.connected? ? 1 : 0

        # Do we want to return empty desks (depends on the frontend)
        next if !return_empty_spaces && occupied == 0

        {
          location:    "desk",
          at_location: occupied,
          map_id:      port.desk_id,
          level:       port.level_id,
          building:    @building_zone,
          capacity:    1,
          mac:         port.mac,
          port:        port_num,
          switch:      port.switch_serial,
        }
      end
    }.flatten
  end

  # ======================
  # Sensor interface:
  # ======================

  protected def to_sensors(zone_id, filter, camera, details, building, level)
    sensors = [] of Interface::Sensor::Detail
    return sensors if zone_id && (building || level) && !zone_id.in?({building, level})

    formatted_mac = format_mac(camera.mac)

    {SensorType::PeopleCount, SensorType::Presence}.each do |type|
      next if filter && filter != type

      time = details.ts.to_unix
      type_indicator = type.to_s.underscore.split('_', 2)[0]

      details.zones.each do |area_id, count|
        value = case type
                when SensorType::PeopleCount
                  count.person.to_f
                when SensorType::Presence
                  count.person > 0 ? 1.0 : 0.0
                else
                  # Will never make it here
                  raise "unknown sensor"
                end

        sensor = Interface::Sensor::Detail.new(
          type: type,
          value: value,
          last_seen: time,
          mac: camera.mac,
          id: "#{area_id}-#{type_indicator}",
          name: "#{camera.name} Presence: #{camera.model} (#{camera.serial})",

          module_id: module_id,
          binding: "#{type_indicator}-#{formatted_mac}-#{area_id}"
        )

        sensor.building = building
        sensor.level = level
        sensors << sensor
      end
    end

    sensors
  end

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if type && !type.in?({"Presence", "PeopleCount"})
    filter = type ? SensorType.parse(type) : nil

    if mac
      cam_state = @camera_analytics[format_mac(mac)]?
      return NO_MATCH unless cam_state
      return to_sensors(zone_id, filter, **cam_state)
    end

    @camera_analytics.values.flat_map { |cam_data| to_sensors(zone_id, filter, **cam_data) }
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }

    return nil unless id
    cam_state = @camera_analytics[format_mac(mac)]?
    return nil unless cam_state

    # https://crystal-lang.org/api/1.1.0/String.html#rpartition(search:Char%7CString):Tuple(String,String,String)-instance-method
    area_str, _, sensor_type = id.rpartition('-')

    filter = case sensor_type
             when "people"
               SensorType::PeopleCount
             when "presence"
               SensorType::Presence
             else
               return nil
             end

    area_id = area_str.to_i64?
    return nil unless area_id

    zone_count = cam_state[:details].zones[area_id]?.try &.person
    return nil unless zone_count

    to_sensors(nil, filter, **cam_state).find { |sensor| sensor.id == id }
  end

  # =================
  # Camera Desk data:
  # =================
  # desk_id => [{time, occupied}]
  getter desk_occupancy : Hash(String, Array(Tuple(Int64, Bool)))

  @desk_occupancy : Hash(String, Array(Tuple(Int64, Bool))) = Hash(String, Array(Tuple(Int64, Bool))).new do |hash, key|
    hash[key] = Array(Tuple(Int64, Bool)).new(4)
  end

  protected def average_results(serial, detected)
    desks = @desk_mappings[serial]?
    return unless desks

    time = Time.utc.to_unix
    past = desk_data_expiry_time

    # id => Array({distance, occupied})
    results = Hash(String, Array(Tuple(Float64, Bool))).new { |h, k| h[k] = [] of Tuple(Float64, Bool) }

    # we store the closest desk point to the line,
    # as this detected desk might be the occupancy we care about
    detected.desks.each do |(lx, ly, cx, cy, rx, ry, occupancy)|
      desks.each { |desk| desk.distance = calculate_distance(lx, ly, cx, cy, rx, ry, desk) }
      if desk = desks.sort! { |a, b| a.distance <=> b.distance }.first?
        results[desk.label] << {desk.distance, !occupancy.zero?}
      end
    end

    # then for each desk id, we take the closest detected desk and use that
    # occupancy value
    results.each do |desk_id, distances|
      _distance, occupancy = distances.sort! { |a, b| a[0] <=> b[0] }.first
      desk_occupation = @desk_occupancy[desk_id]
      desk_occupation << {time, occupancy}
      cleanup_old_data(desk_occupation, past)
    end
  end

  # We want to find the line closest to the offical desk point
  protected def calculate_distance(lx, ly, cx, cy, rx, ry, desk)
    desk = Point.new(desk.x, desk.y)
    {
      Point.new(lx, ly).distance_to(desk),
      Point.new(rx, ry).distance_to(desk),
      Point.new(cx, cy).distance_to(desk),
    }.sum
  end

  protected def desk_data_expiry_time
    90.seconds.ago.to_unix
  end

  protected def cleanup_old_data(desk_occupation, expiry_time)
    desk_occupation.reject! { |(time, _occupancy)| time < expiry_time }
  end

  # =============================
  # Camera Desk location service:
  # =============================
  # zone_id => array of camera serials
  @zone_lookup : Hash(String, Array(String)) = {} of String => Array(String)

  # camera serial => level + building
  @floor_lookup : Hash(String, FloorMapping) = {} of String => FloorMapping

  # Camera serial => [desk location]
  getter desk_mappings : Hash(String, Array(CameraZone)) = {} of String => Array(CameraZone)

  def desk_locations(zone_id : String)
    serials = @zone_lookup[zone_id]? || [] of String
    return_empty_spaces = @return_empty_spaces
    expiry_time = desk_data_expiry_time

    serials.compact_map { |serial|
      desks = @desk_mappings[serial]?
      next unless desks

      # does data exist for the desks?
      next unless desk_details[serial]?

      floor = @floor_lookup[serial]
      illumination = lux[serial]?

      desks.compact_map do |desk|
        desk_id = desk.label
        occupied = is_occupied?(desk_id, expiry_time)

        # Do we want to return empty desks (depends on the frontend)
        next if !return_empty_spaces && occupied == 0

        {
          location:    "desk",
          at_location: occupied,
          map_id:      desk_id,
          level:       floor.level_id,
          building:    floor.building_id,
          capacity:    1,

          area_lux: illumination,
          merakimv: serial,
        }
      end
    }.flatten
  end

  def update_desk_mappings
    desk_mappings = Hash(String, Array(CameraZone)).new
    @floor_lookup.keys.each do |serial|
      begin
        desk_mappings[serial] = Array(CameraZone).from_json(dashboard.get_zones(serial).get.to_json).reject!(&.id.==("0"))
      rescue error
        logger.warn(exception: error) { "fetching zones for camera: #{serial}" }
      end
    end

    @desk_mappings = desk_mappings

    mqtt_module = system[:MerakiMQTT]
    desk_mappings.keys.each { |camera_serial| check_camera_status(mqtt_module, camera_serial) }
  end

  protected def desk_data_expiry_time
    90.seconds.ago.to_unix
  end

  protected def is_occupied?(desk_id, expiry_time)
    desk_occupation = @desk_occupancy[desk_id]?
    return 0 unless desk_occupation

    occupied = 0
    desk_occupation.reject! do |(time, occupancy)|
      if time < expiry_time
        next true
      elsif occupancy
        occupied += 1
      end
      false
    end

    size = desk_occupation.size
    return 0 if size.zero?

    # We care if the desk basically had signs of life
    (occupied / size) > 0.3 ? 1 : 0
  end
end
