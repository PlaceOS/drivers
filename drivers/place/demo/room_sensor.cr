require "placeos-driver"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/locatable"

class Place::Demo::RoomSensor < PlaceOS::Driver
  include Interface::Sensor
  include Interface::Locatable

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
    @sensor_id = setting?(String, :sensor_id) || module_id
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

  # Finds the building ID for the current location services object
  getter building_id : String do
    zone_ids = system["StaffAPI"].zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    raise error
  end

  # Finds the level ID for the current location services object
  getter level_id : String do
    zone_ids = system["StaffAPI"].zones(tags: "level").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    raise error
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

  # ===================================
  # Locatable Interface functions
  # ===================================
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
    return [] of Nil unless {building_id, level_id}.includes?(zone_id)
    return [] of Nil if location && location != "area"

    [{
      location:    "area",
      at_location: count,
      map_id:      system.map_id,
      level:       level_id,
      building:    building_id,
      capacity:    @capacity,

      module_id: module_id,

    }]
  end
end
