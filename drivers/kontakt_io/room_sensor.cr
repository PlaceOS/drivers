require "placeos-driver"
require "./kio_cloud_models"
require "placeos-driver/interface/sensor"

class KontaktIO::RoomSensor < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "KontaktIO Room Sensor"
  generic_name :Sensor

  default_settings({
    space_ref_id: "kontakt-room-id",
  })

  accessor kontakt_io : KontaktIO_1

  @space_id : String = ""

  getter! space : RoomOccupancy

  def on_load
    on_update
  end

  def on_update
    @space_id = setting(String, :space_ref_id)
    subscriptions.clear
    schedule.clear

    # Level sensors
    subscribe_to_sensor
  end

  protected def subscribe_to_sensor : Nil
    system.subscribe(:KontaktIO, 1, "room-#{@space_id}") { |_sub, room| update_sensor_state(room) }
  rescue error
    schedule.in(15.seconds) { subscribe_to_sensor }
    logger.warn(exception: error) { "attempting to bind to sensor details" }
    self[:last_error] = error.message
  end

  protected def update_sensor_state(room_json : String)
    @space = space = RoomOccupancy.from_json(room_json)
    raise "space '#{@space_id}' not found" unless space

    self[:last_changed] = space.last_update
    people_count = space.occupancy

    self[:presence] = people_count > 0
    self[:people] = people_count
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }
    sensor = @space
    return NO_MATCH unless sensor

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac == "kontakt-#{sensor.room_id}"
    end

    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    build_sensors(sensor, sensor_type)
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    sensor = @space
    return nil unless sensor
    return nil unless mac == "kontakt-#{sensor.room_id}"

    case id
    when "people"
      build_sensor_details(sensor, :people_count)
    when "presence"
      build_sensor_details(sensor, :presence)
    end
  end

  protected def build_sensor_details(room : RoomOccupancy, sensor : SensorType) : Detail
    id = "people"
    value = case sensor
            when .people_count?
              room.occupancy.to_f64
            when .presence?
              id = "presence"
              room.occupancy > 0 ? 1.0 : 0.0
            else
              raise "sensor type unavailable: #{sensor}"
            end

    detail = Detail.new(
      type: sensor,
      value: value,
      last_seen: room.last_update.to_unix,
      mac: "kontakt-#{room.room_id}",
      id: id,
      name: "#{room.floor_name} #{room.room_name} (#{room.building_name})",
      module_id: module_id,
      binding: id
    )
    detail
  end

  protected def build_sensors(room : RoomOccupancy, sensor : SensorType? = nil)
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
