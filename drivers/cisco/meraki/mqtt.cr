require "./mqtt_models"
require "placeos-driver"
require "placeos-driver/interface/sensor"
require "../../place/mqtt_transport_adaptor"

# documentation: https://developer.cisco.com/meraki/mv-sense/#!mqtt

class Cisco::Meraki::MQTT < PlaceOS::Driver
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
  })

  SUBS = {
    # Meraki desk occupancy (coords and occupancy are floats)
    # {ts: unix_time, desks: [[lx, ly, rx, ry, cx, cy, occupancy], [...]]}
    "merakimv/+/net.meraki.detector",

    # lux levels on a camera
    # {lux: float}
    "merakimv/+/light",

    # Number of entrances in the camera’s complete field of view
    # {ts: unix_time, counts: {person: number, vehicle: number}}
    "merakimv/+/0",
  }

  @keep_alive : Int32 = 60
  @username : String? = nil
  @password : String? = nil
  @client_id : String = "placeos"

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
    @username = setting?(String, :username)
    @password = setting?(String, :password)
    @keep_alive = setting?(Int32, :keep_alive) || 60
    @client_id = setting?(String, :client_id) || ::MQTT.generate_client_id("placeos_")

    existing = @subs
    @subs = SUBS.dup

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
    perform_operation { @mqtt.not_nil!.ping }
  end

  def received(data, task)
    logger.debug { "received #{data.size} bytes: 0x#{data.hexstring}" }
    @transport.try &.process(data)
    task.try &.success
  end

  getter people_counts : Hash(String, Hash(String, Tuple(Int32, Int64))) do
    Hash(String, Hash(String, Tuple(Int32, Int64))).new do |hash, key|
      hash[key] = {} of String => Tuple(Int32, Int64)
    end
  end

  getter vehicle_counts : Hash(String, Hash(String, Tuple(Int32, Int64))) do
    Hash(String, Hash(String, Tuple(Int32, Int64))).new do |hash, key|
      hash[key] = {} of String => Tuple(Int32, Int64)
    end
  end

  getter lux : Hash(String, Tuple(Float32, Int64)) = {} of String => Tuple(Float32, Int64)

  # this is where we do all of the MQTT message processing
  protected def on_message(key : String, playload : Bytes) : Nil
    json_message = String.new(playload)
    _merakimv, serial_no, status = key.split("/")

    case status
    when "net.meraki.detector"
      # we assume version 3 of the API here for sanity reasons
      self["camera_#{serial_no}_desks"] = DetectedDesks.from_json(json_message)
    when "light"
      light = LuxLevel.from_json(json_message)
      lux[serial_no] = {light.lux, Time.utc.to_unix}
      self["camera_#{serial_no}_lux"] = light.lux
    else
      # Everything else is a zone count
      entry = Entrances.from_json json_message
      case entry.count_type
      in CountType::People
        people_counts[serial_no][status] = {entry.count, Time.unix_ms(entry.timestamp).to_unix}
      in CountType::Vehicles
        vehicle_counts[serial_no][status] = {entry.count, Time.unix_ms(entry.timestamp).to_unix}
      in CountType::Unknown
        # ignore
      end
      self["camera_#{serial_no}_zone#{status}_#{entry.count_type.to_s.downcase}"] = entry.count
    end
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
          if count = lookup[zone]?
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

    sensors = [] of Detail
    filter = type ? Interface::Sensor::SensorType.parse?(type) : nil

    case filter
    when nil
      add_lux_values(sensors, mac)
      add_people_counts(sensors, mac)
      add_vehicle_counts(sensors, mac)
    when .people_count?
      add_people_counts(sensors, mac)
    when .counter?
      add_vehicle_counts(sensors, mac)
    when .illuminance?
      add_lux_values(sensors, mac)
    else
      sensors
    end
  rescue error
    logger.warn(exception: error) { "searching for sensors" }
    NO_MATCH
  end

  protected def add_people_counts(sensors, mac : String? = nil)
    if cam_counts = people_counts[mac]?
      serial, zones = cam_counts
      zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::PeopleCount, serial, "zone#{zone_name}_people", count, time) }
    else
      people_counts.each { |serial, zones| zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::PeopleCount, serial, "zone#{zone_name}_people", count, time) } }
    end
    sensors
  end

  protected def add_vehicle_counts(sensors, mac : String? = nil)
    if cam_counts = vehicle_counts[mac]?
      serial, zones = cam_counts
      zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::Counter, serial, "zone#{zone_name}_vehicles", count, time) }
    else
      vehicle_counts.each { |serial, zones| zones.each { |zone_name, (count, time)| sensors << to_sensor(SensorType::Counter, serial, "zone#{zone_name}_vehicles", count, time) } }
    end
    sensors
  end

  protected def add_lux_values(sensors, mac : String? = nil)
    if lux_val = lux[mac]?
      level, time = lux_val
      sensors << to_sensor(SensorType::Illuminance, mac, LUX_ID, level, time)
    else
      lux.each { |serial, (level, time)| sensors << to_sensor(SensorType::Illuminance, serial, LUX_ID, level, time) }
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
end
