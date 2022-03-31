require "./mqtt_models"
require "placeos-driver"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/locatable"
require "../../place/mqtt_transport_adaptor"
require "../../place/area_polygon"

# documentation: https://developer.cisco.com/meraki/mv-sense/#!mqtt
# Use https://www.desmos.com/calculator for plotting points (sample code for copy and paste)
# data = [[1,2,3,4,5,6, 0]]
# data.each do |d|
# 	puts "(#{d[0]}, #{d[1]}),(#{d[2]}, #{d[3]}),(#{d[4]}, #{d[5]})"
# end

class Cisco::Meraki::MQTT < PlaceOS::Driver
  include Interface::Locatable
  include Interface::Sensor

  descriptive_name "Meraki MQTT"
  generic_name :MerakiMQTT

  tcp_port 1883
  description %(subscribes to Meraki MV Sense camera data)

  default_settings({
    username:   "user",
    password:   "pass",
    keep_alive: 60,
    client_id:  "placeos",

    floor_mappings: [
      {
        camera_serials: ["1234", "camera_serial"],
        level_id:       "zone-123",
        building_id:    "zone-456",
      },
    ],

    desk_mappings: {
      camera_serial: [{
        id: "desk-1234",
        x:  0.44,
        y:  0.56,
      }],
    },

    return_empty_spaces: true,
  })

  SUBS = {
    # Meraki desk occupancy (coords and occupancy are floats)
    # {ts: unix_time, desks: [[lx, ly, rx, ry, cx, cy, occupancy], [...]]}
    "/merakimv/+/net.meraki.detector",

    # lux levels on a camera
    # {lux: float}
    "/merakimv/+/light",

    # Number of entrances in the camera’s complete field of view
    # {ts: unix_time, counts: {person: number, vehicle: number}}
    "/merakimv/+/0",
  }

  @keep_alive : Int32 = 60
  @username : String? = nil
  @password : String? = nil
  @client_id : String = "placeos"
  @return_empty_spaces : Bool = true

  @mqtt : ::MQTT::V3::Client? = nil
  @subs : Array(String) = [] of String
  @transport : Place::TransportAdaptor? = nil
  @sub_proc : Proc(String, Bytes, Nil) = Proc(String, Bytes, Nil).new { |_key, _payload| nil }

  def on_load
    @sub_proc = Proc(String, Bytes, Nil).new { |key, payload| on_message(key, payload) }
    on_update
  end

  def on_unload
  end

  def on_update
    @return_empty_spaces = setting?(Bool, :return_empty_spaces) || false
    @username = setting?(String, :username)
    @password = setting?(String, :password)
    @keep_alive = setting?(Int32, :keep_alive) || 60
    @client_id = setting?(String, :client_id) || ::MQTT.generate_client_id("placeos_")

    # zone_id => camera serial
    zone_lookup = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
    # camera serial => level + building
    floor_lookup = {} of String => FloorMapping
    floor_mappings = setting?(Array(FloorMapping), :floor_mappings) || [] of FloorMapping
    floor_mappings.each do |mapping|
      mapping.camera_serials.each do |serial|
        zone_lookup[mapping.level_id] << serial
        zone_lookup[mapping.building_id.not_nil!] << serial if mapping.building_id
        floor_lookup[serial] = mapping
      end
    end
    @floor_lookup = floor_lookup
    @zone_lookup = zone_lookup

    @desk_mappings = setting?(Hash(String, Array(DeskLocation)), :desk_mappings) || {} of String => Array(DeskLocation)

    existing = @subs
    @subs = SUBS.to_a

    # TODO:: obtain MV Sense zone data here from API and add zones to subs

    schedule.clear
    schedule.every((@keep_alive // 3).seconds) { ping }

    if client = @mqtt
      unsub = existing - @subs
      newsub = @subs - existing

      unsub.each do |sub|
        logger.debug { "unsubscribing to #{sub}" }
        client.unsubscribe(sub)
      end

      newsub.each do |sub|
        logger.debug { "subscribing to #{sub}" }
        client.subscribe(sub, &@sub_proc)
      end
    end
  end

  def connected
    transp = Place::TransportAdaptor.new(transport, queue)
    client = ::MQTT::V3::Client.new(transp)
    @transport = transp
    @mqtt = client

    logger.debug { "sending connect message" }
    client.connect(@username, @password, @keep_alive, @client_id)
    @subs.each do |sub|
      logger.debug { "subscribing to #{sub}" }
      client.subscribe(sub, &@sub_proc)
    end
  end

  def disconnected
    @transport = nil
    @mqtt = nil
  end

  def ping
    logger.debug { "sending ping" }
    @mqtt.not_nil!.ping
  end

  def received(data, task)
    logger.debug { "received #{data.size} bytes: 0x#{data.hexstring}" }
    @transport.try &.process(data)
    task.try &.success
  end

  getter people_counts : Hash(String, Hash(String, Tuple(Float64, Int64))) do
    Hash(String, Hash(String, Tuple(Float64, Int64))).new do |hash, key|
      hash[key] = {} of String => Tuple(Float64, Int64)
    end
  end

  getter vehicle_counts : Hash(String, Hash(String, Tuple(Float64, Int64))) do
    Hash(String, Hash(String, Tuple(Float64, Int64))).new do |hash, key|
      hash[key] = {} of String => Tuple(Float64, Int64)
    end
  end

  getter lux : Hash(String, Tuple(Float64, Int64)) = {} of String => Tuple(Float64, Int64)

  getter desk_details : Hash(String, DetectedDesks) = {} of String => DetectedDesks

  # this is where we do all of the MQTT message processing
  protected def on_message(key : String, playload : Bytes) : Nil
    json_message = String.new(playload)
    key = key[1..-1] if key.starts_with?("/")

    logger.debug { "new message: #{key} = #{json_message}" }
    _merakimv, serial_no, status = key.split("/")

    case status
    when "net.meraki.detector"
      # we assume version 3 of the API here for sanity reasons
      detected_desks = DetectedDesks.from_json(json_message)
      desk_details[serial_no] = detected_desks
      average_results(serial_no, detected_desks)
      self["camera_#{serial_no}_desks"] = detected_desks
    when "light"
      light = LuxLevel.from_json(json_message)
      lux[serial_no] = {light.lux, light.timestamp}
      self["camera_#{serial_no}_lux"] = light.lux
    else
      # Everything else is a zone count
      entry = Entrances.from_json json_message
      case entry.count_type
      in CountType::People
        people_counts[serial_no][status] = {entry.count.to_f64, Time.unix_ms(entry.timestamp).to_unix}
      in CountType::Vehicles
        vehicle_counts[serial_no][status] = {entry.count.to_f64, Time.unix_ms(entry.timestamp).to_unix}
      in CountType::Unknown
        # ignore
      end
      self["camera_#{serial_no}_zone#{status}_#{entry.count_type.to_s.downcase}"] = entry.count
    end
  end

  @desk_occupancy = Hash(String, Array(Tuple(Int64, Bool))).new do |hash, key|
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
        results[desk.id] << {desk.distance, !occupancy.zero?}
      end
    end

    # then for each desk id, we take the closest detected desk and use that
    # occupancy value
    results.each do |desk_id, distances|
      distance, occupancy = distances.sort! { |a, b| a[0] <=> b[0] }.first
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

  protected def is_occupied?(desk_id, expiry_time)
    desk_occupation = @desk_occupancy[desk_id]
    size = desk_occupation.size
    return 0 if size == 0

    desk_occupation.reject! do |(time, _occupancy)|
      if time < expiry_time && size > 1
        size -= 1
        true
      else
        break
      end
    end

    occupied = 0
    desk_occupation.each { |(_time, occupancy)| occupied += 1 if occupancy }

    # We care if the desk basically had signs of life
    (occupied / size) > 0.3 ? 1 : 0
  end

  # ----------------
  # Sensor Interface
  # ----------------

  # return the specified sensor details
  def sensor(mac : String, id : String? = nil) : Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id

    if id == "lux"
      add_lux_values([] of Detail, mac).first?
    elsif id.starts_with? "zone"
      zone, count_type = id.split('_', 2)
      zone = zone[4..-1] # remove the word "zone"

      sensor_type = SensorType::PeopleCount
      lookup = case count_type
               when "people"
                 people_counts
               when "vehicles"
                 sensor_type = SensorType::Counter
                 vehicle_counts
               end

      if lookup
        if counts = lookup[mac]?
          if count = counts[zone]?
            to_sensor(sensor_type, mac, "zone#{zone}_#{count_type}", count[0], count[1])
          end
        end
      end
    else
      nil
    end
  end

  NO_MATCH = [] of Interface::Sensor::Detail
  LUX_ID   = "lux"

  # return an array of sensor details
  # zone_id can be ignored if location is unknown by the sensor provider
  # mac_address can be used to grab data from a single device (basic grouping)
  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    serial_filter = nil
    if zone_id && !@floor_lookup.empty?
      serial_filter = [] of String
      @floor_lookup.each do |serial, floor|
        serial_filter << serial if {floor.level_id, floor.building_id}.includes?(zone_id)
      end
    end

    sensors = [] of Detail
    filter = type ? Interface::Sensor::SensorType.parse?(type) : nil

    case filter
    when nil
      add_lux_values(sensors, mac, serial_filter)
      add_people_counts(sensors, mac, serial_filter)
      add_vehicle_counts(sensors, mac, serial_filter)
    when .people_count?
      add_people_counts(sensors, mac, serial_filter)
    when .counter?
      add_vehicle_counts(sensors, mac, serial_filter)
    when .illuminance?
      add_lux_values(sensors, mac, serial_filter)
    else
      sensors
    end
  rescue error
    logger.warn(exception: error) { "searching for sensors" }
    NO_MATCH
  end

  protected def add_people_counts(sensors, mac : String? = nil, serial_filter : Array(String)? = nil)
    if mac
      return sensors if serial_filter && !serial_filter.includes?(mac)
      people_counts[mac]?.try &.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::PeopleCount, mac, "zone#{zone_name}_people", count, time) }
    else
      people_counts.each do |serial, zones|
        next if serial_filter && !serial_filter.includes?(serial)
        zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::PeopleCount, serial, "zone#{zone_name}_people", count, time) }
      end
    end
    sensors
  end

  protected def add_vehicle_counts(sensors, mac : String? = nil, serial_filter : Array(String)? = nil)
    if mac
      return sensors if serial_filter && !serial_filter.includes?(mac)
      vehicle_counts[mac]?.try &.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::Counter, mac, "zone#{zone_name}_vehicles", count, time) }
    else
      vehicle_counts.each do |serial, zones|
        next if serial_filter && !serial_filter.includes?(serial)
        zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::Counter, serial, "zone#{zone_name}_vehicles", count, time) }
      end
    end
    sensors
  end

  protected def add_lux_values(sensors, mac : String? = nil, serial_filter : Array(String)? = nil)
    if mac
      return sensors if serial_filter && !serial_filter.includes?(mac)
      if lux_val = lux[mac]?
        level, time = lux_val
        sensors << to_sensor(SensorType::Illuminance, mac, LUX_ID, level, time)
      end
    else
      lux.each do |serial, (level, time)|
        next if serial_filter && !serial_filter.includes?(serial)
        sensors << to_sensor(SensorType::Illuminance, serial, LUX_ID, level, time)
      end
    end
    sensors
  end

  protected def to_sensor(sensor_type, serial, id, value, timestamp) : Interface::Sensor::Detail
    Interface::Sensor::Detail.new(
      type: sensor_type,
      value: value,
      last_seen: timestamp,
      mac: serial,
      id: id,
      name: "Meraki Camera #{serial}: #{id}",
      module_id: module_id,
      binding: "camera_#{serial}_#{id}",
      unit: sensor_type.illuminance? ? "lx" : nil
    )
  end

  # -------------------
  # Locatable Interface
  # -------------------
  @zone_lookup : Hash(String, Array(String)) = {} of String => Array(String)
  @floor_lookup : Hash(String, FloorMapping) = {} of String => FloorMapping
  @desk_mappings : Hash(String, Array(DeskLocation)) = {} of String => Array(DeskLocation)

  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "sensor incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "sensor incapable of tracking #{email} or #{username}" }
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "sensor incapable of tracking #{mac_address}" }
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }

    return [] of Nil if location.presence && location != "desk"

    serials = @zone_lookup[zone_id]?
    return [] of Nil unless serials && !serials.empty?

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
        desk_id = desk.id
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
end
