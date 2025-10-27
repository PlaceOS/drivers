require "placeos-driver"
require "./models"
require "placeos-driver/interface/sensor"

class Floorsense::RoomSensorDriver < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Floorsense Room Sensor"
  generic_name :Sensor

  default_settings({
    _floorsense_system: "sys-12345",
    _floorsense_module: "Floorsense",

    floorsense_room_id: "1",
  })

  getter system_id : String = ""
  getter module_name : String = ""
  getter room_id : String = ""

  def on_update
    @system_id = setting?(String, :floorsense_system).presence || config.control_system.not_nil!.id
    @module_name = setting?(String, :floorsense_module).presence || "Floorsense"
    @room_id = setting(String | Int64, :floorsense_room_id).to_s

    schedule.clear
    schedule.every(15.seconds + rand(1000).milliseconds) { update_sensor }
    schedule.in(rand(200).milliseconds) { update_sensor }
  end

  private def floorsense
    system(system_id)[module_name]
  end

  getter! status : RoomStatus

  def update_sensor : RoomStatus?
    status = Array(RoomStatus).from_json floorsense.room_list(room_id).get.to_json
    if state = status.first?
      @status = state

      self[:last_changed] = state.cached
      self[:presence] = state.occupiedcount > 0
      self[:people] = state.occupiedcount
    else
      @status = nil
      self[:last_changed] = nil
      self[:presence] = nil
      self[:people] = nil
    end
    @status
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }
    sensor = @status
    return NO_MATCH unless sensor

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac == "floorsense-#{sensor.roomid}"
    end

    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    build_sensors(sensor, sensor_type)
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    sensor = @status
    return nil unless sensor
    return nil unless mac == "floorsense-#{sensor.roomid}"

    case id
    when "people"
      build_sensor_details(sensor, :people_count)
    when "presence"
      build_sensor_details(sensor, :presence)
    end
  end

  protected def build_sensor_details(room : RoomStatus, sensor : SensorType) : Detail
    id = "people"
    value = case sensor
            when .people_count?
              room.occupiedcount.to_f64
            when .presence?
              id = "presence"
              room.occupiedcount > 0 ? 1.0 : 0.0
            else
              raise "sensor type unavailable: #{sensor}"
            end

    detail = Detail.new(
      type: sensor,
      value: value,
      last_seen: room.cached,
      mac: "floorsense-#{room.roomid}",
      id: id,
      name: room.name,
      module_id: module_id,
      binding: id
    )
    detail
  end

  protected def build_sensors(room : RoomStatus, sensor : SensorType? = nil)
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
