require "placeos-driver"
require "placeos-driver/interface/sensor"

class Cisco::SpacesRoom < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "Cisco Spaces Room Sensors"
  generic_name :SpacesRoomSensors
  description "exposes sensor information to the room"

  default_settings({
    _cisco_spaces_system: "sys-12345",
    _cisco_spaces_module: "Cisco_Spaces",

    space_room_id: "a410b6d676",
  })

  getter system_id : String = ""
  getter module_name : String = ""
  getter room_id : String = ""

  def on_update
    @system_id = setting?(String, :cisco_spaces_system).presence || config.control_system.not_nil!.id
    @module_name = setting?(String, :cisco_spaces_module).presence || "Cisco_Spaces"
    @room_id = setting(String, :space_room_id)
  end

  private def cisco_spaces
    system(system_id)[module_name]
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence, SensorType::Humidity, SensorType::Temperature, SensorType::AirQuality, SensorType::SoundPressure}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if mac && mac != @room_id
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end
    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    Array(Interface::Sensor::Detail).from_json cisco_spaces.sensors(type, @room_id, zone_id).get.to_json
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    return nil unless mac == @room_id

    Interface::Sensor::Detail?.from_json(cisco_spaces.sensors(@room_id, id).get.to_json)
  end
end
