require "placeos-driver"
require "placeos-driver/interface/sensor"

class Place::Demo::RoomSensor < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Demo Room Sensor"
  generic_name :Sensor

  default_settings({
    sensor_id:     "1234",
    capacity:      2,
    default_count: 0,
  })

  @sensor_id : String = "1234"
  @capacity : Int32 = 2
  getter! count : Int32
  @timestamp : Int64 = 0_i64

  def on_load
    on_update
  end

  def on_update
    @capacity = setting?(Int32, :capacity) || 2
    @count ||= setting?(Int32, :default_count) || 0
    @sensor_id = setting?(String, :sensor_id) || "1234"
    @timestamp = Time.utc.to_unix
    update_state
  end

  def set_sensor(new_count : Int32)
    @timestamp = Time.utc.to_unix
    @count = new_count
    update_state
  end

  protected def update_state
    self["people"] = count
    self["presence"] = count > 0
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if mac && mac != "demo-#{@sensor_id}"
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end
    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    if sensor_type
      sensor = build_sensor_details(sensor_type)
      return NO_MATCH unless sensor
      [sensor]
    else
      space_sensors
    end
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    return nil unless mac == "demo-#{@sensor_id}"

    case id
    when "people"
      build_sensor_details(:people_count)
    when "presence"
      build_sensor_details(:presence)
    end
  end

  protected def build_sensor_details(sensor : SensorType) : Detail?
    time = @timestamp
    id = "people"

    value = case sensor
            when .people_count?
              count.to_f64
            when .presence?
              id = "presence"
              count > 0 ? 1.0 : 0.0
            else
              raise "sensor type unavailable: #{sensor}"
            end
    return nil unless value

    Detail.new(
      type: sensor,
      value: value,
      last_seen: time,
      mac: "demo-#{@sensor_id}",
      id: id,
      name: "Demo Sensor (#{@sensor_id})",
      module_id: module_id,
      binding: id
    )
  end

  protected def space_sensors
    [
      build_sensor_details(:people_count),
      build_sensor_details(:presence),
    ].compact
  end
end
