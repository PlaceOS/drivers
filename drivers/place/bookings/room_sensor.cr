require "placeos-driver"
require "placeos-driver/interface/sensor"

class Place::Bookings::RoomSensor < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Area People Count"
  generic_name :Sensor

  default_settings({
    _area_management_system: "sys-12345",
    _area_id:                "not required if matching system.map_id",
  })

  getter system_id : String = ""
  getter area_id : String = ""

  getter level_id : String do
    (area_management.level_buildings.get.as_h.keys & config.control_system.not_nil!.zones).first
  end

  def on_update
    @system_id = setting?(String, :area_management_system).presence || config.control_system.not_nil!.id
    @area_id = setting?(String, :area_id) || config.control_system.not_nil!.map_id.as(String)

    schedule.clear
    schedule.every(15.seconds + rand(1000).milliseconds) { update_sensor; nil }
    schedule.in(rand(200).milliseconds) { update_sensor; nil }
  end

  private def area_management
    system(system_id).get("AreaManagement", 1)
  end

  record AreaCounts, area_id : String, name : String, count : Float64, counter : Float64? do
    include JSON::Serializable
  end

  record ZoneAreas, value : Array(AreaCounts) do
    include JSON::Serializable
  end

  getter! counts : AreaCounts
  @last_seen : Int64 = 0_i64

  def update_sensor : AreaCounts?
    id = area_id

    if counts = area_management.status?(ZoneAreas, "#{level_id}:areas").try(&.value.find { |area| area.area_id == id })
      @counts = counts

      count = counts.counter || counts.count
      count = 0.0 if count < 0.0

      self[:last_changed] = @last_seen = Time.utc.to_unix
      self[:presence] = count.zero? ? 0.0 : 1.0
      self[:people] = count
    else
      @counts = nil
      self[:last_changed] = nil
      self[:presence] = nil
      self[:people] = nil
    end

    @counts
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }
    sensor = @counts
    return NO_MATCH unless sensor

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac == "area-#{sensor.area_id}"
    end

    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    build_sensors(sensor, sensor_type)
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    sensor = @counts
    return nil unless sensor
    return nil unless mac == "area-#{sensor.area_id}"

    case id
    when "people"
      build_sensor_details(sensor, :people_count)
    when "presence"
      build_sensor_details(sensor, :presence)
    end
  end

  protected def build_sensor_details(room : AreaCounts, sensor : SensorType) : Detail
    id = "people"

    count = room.counter || room.count
    count = 0.0 if count < 0.0

    value = case sensor
            when .people_count?
              count
            when .presence?
              id = "presence"
              count.zero? ? 0.0 : 1.0
            else
              raise "sensor type unavailable: #{sensor}"
            end

    detail = Detail.new(
      type: sensor,
      value: value,
      last_seen: @last_seen,
      mac: "area-#{room.area_id}",
      id: id,
      name: room.name,
      module_id: module_id,
      binding: id
    )
    detail
  end

  protected def build_sensors(room : AreaCounts, sensor : SensorType? = nil)
    if sensor
      [build_sensor_details(room, sensor)]
    else
      [
        build_sensor_details(room, :people_count),
        build_sensor_details(room, :presence),
      ]
    end
  end
end
