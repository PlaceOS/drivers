require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./models"

class Vergesense::RoomSensor < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Vergesense Room Sensor"
  generic_name :Sensor

  default_settings({
    space_ref_id: "vergesense-room-id",
  })

  accessor vergesense : Vergesense_1

  @space_id : String = ""
  @floor_key : String = ""

  getter! space : Space
  getter! floor_name : String

  def on_update
    @space_id = setting(String, :space_ref_id)
    subscriptions.clear
    schedule.clear

    # Level sensors
    system.subscribe(:Vergesense, 1, "init_complete") do |_sub, value|
      subscribe_to_sensor if value == "true"
    end
  end

  protected def subscribe_to_sensor : Nil
    @floor_key = vergesense.floor_key(@space_id).get.as_s
    system.subscribe(:Vergesense, 1, @floor_key) { |_sub, floor| update_sensor_state(floor) }
    self[:floor_key] = @floor_key
  rescue error
    schedule.in(15.seconds) { subscribe_to_sensor }
    logger.warn(exception: error) { "attempting to bind to sensor details" }
    self[:last_error] = error.message
    self[:floor_key] = "unknown space_ref_id in settings"
  end

  protected def update_sensor_state(level : String)
    floor = Floor.from_json(level)
    @floor_name = floor.name
    @space = floor_space = floor.spaces.find { |space| space.space_ref_id == @space_id }
    raise "space '#{@space_id}' not found" unless floor_space

    self[:last_changed] = Time.utc.to_unix

    people_count = floor_space.people.try &.count
    if people_count
      self[:presence] = people_count > 0
      self[:people] = people_count
    else
      self[:presence] = false
      self[:people] = 0
    end

    self[:humidity] = floor_space.environment.try &.humidity.value
    self[:temperature] = floor_space.environment.try &.temperature.value
    self[:air_quality] = floor_space.environment.try(&.iaq.try(&.value))

    self[:capacity] = floor_space.max_capacity || floor_space.capacity
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence, SensorType::Humidity, SensorType::Temperature, SensorType::AirQuality}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if mac && mac != "verg-#{@space_id}"
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
    return nil unless mac == "verg-#{@space_id}"

    case id
    when "people"
      build_sensor_details(:people_count)
    when "presence"
      build_sensor_details(:presence)
    when "humidity"
      build_sensor_details(:humidity)
    when "temperature"
      build_sensor_details(:temperature)
    when "air_quality"
      build_sensor_details(:air_quality)
    end
  end

  protected def build_sensor_details(sensor : SensorType) : Detail?
    time = space.timestamp || space.environment.try(&.timestamp) || Time.utc
    id = "people"
    limit_high = nil
    value = case sensor
            when .people_count?
              limit_high = (space.max_capacity || space.capacity).try &.to_f64
              space.people.try &.count.try &.to_f64
            when .presence?
              id = "presence"
              space.people.try &.count.try { |count| count > 0 ? 1.0 : 0.0 } || 0.0
            when .humidity?
              id = "humidity"
              space.environment.try &.humidity.value
            when .temperature?
              id = "temperature"
              space.environment.try &.temperature.value
            when .air_quality?
              id = "air_quality"
              space.environment.try(&.iaq.try(&.value))
            else
              raise "sensor type unavailable: #{sensor}"
            end
    return nil unless value

    Detail.new(
      type: sensor,
      value: value,
      last_seen: time.to_unix,
      mac: "verg-#{@space_id}",
      id: id,
      name: "#{floor_name} #{space.name} (#{space.space_type})",
      limit_high: limit_high,
      module_id: module_id,
      binding: id
    )
  end

  protected def space_sensors
    [
      build_sensor_details(:people_count),
      build_sensor_details(:presence),
      build_sensor_details(:humidity),
      build_sensor_details(:temperature),
      build_sensor_details(:air_quality),
    ].compact
  end
end
