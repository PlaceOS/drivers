require "placeos-driver"
require "placeos-driver/interface/sensor"

class Steinel::HPD2 < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  generic_name :PeopleCounter
  descriptive_name "Steinel HPD-2"

  # Local network
  uri_base "https://192.168.0.20"

  default_settings({
    basic_auth: {
      username: "admin",
      password: "steinel",
    },
  })

  @mac : String = ""
  getter! state : NamedTuple(
    illuminance: Interface::Sensor::Detail,
    temperature: Interface::Sensor::Detail,
    humidity: Interface::Sensor::Detail,
    presence: Interface::Sensor::Detail,
    people: Interface::Sensor::Detail,
    illuminance_zones: Array(Interface::Sensor::Detail),
    presence_zones: Array(Interface::Sensor::Detail),
    people_zones: Array(Interface::Sensor::Detail),
  )

  def on_load
    on_update
  end

  def on_update
    @mac = URI.parse(config.uri.not_nil!).hostname.not_nil!
    schedule.every(5.seconds) { get_status }
  end

  {% begin %}
  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless @mac == mac
    return nil unless id

    # https://crystal-lang.org/api/1.1.0/String.html#rpartition(search:Char%7CString):Tuple(String,String,String)-instance-method
    sensor, _, index_str = id.rpartition('-')
    if sensor.empty?
      case id
      {% for sensor in %w(humidity temperature presence people illuminance) %}
        when {{sensor}}
          state[{{sensor.id.symbolize}}]
      {% end %}
      end
    elsif index = index_str.to_i?
      case id
      {% for sensor in %w(presence people illuminance) %}
        when {{sensor}}
          state[{{sensor.id.symbolize}}_zones][index]?
      {% end %}
      end
    end
  rescue error
    logger.warn(exception: error) { "checking for sensor" }
    nil
  end
  {% end %}

  alias SensorType = Interface::Sensor::SensorType

  TYPES = {
    illuminance: SensorType::Illuminance,
    temperature: SensorType::Temperature,
    humidity:    SensorType::Humidity,
    presence:    SensorType::Trigger,
    people:      SensorType::Counter,

    illuminance_zones: SensorType::Illuminance,
    presence_zones:    SensorType::Trigger,
    people_zones:      SensorType::Counter,
  }

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }
    return NO_MATCH if mac && mac != @mac
    return state.values.to_a.flatten unless type

    sensor_type = SensorType.parse(type)
    matches = [] of Interface::Sensor::Detail | Array(Interface::Sensor::Detail)
    TYPES.each { |key, key_type| matches << state[key] if key_type == sensor_type }

    matches.flatten
  rescue error
    logger.warn(exception: error) { "searching for sensors" }
    [] of Interface::Sensor::Detail
  end

  def get_status
    response = get("/api/sensorstatus.php")

    logger.debug { "received #{response.body}" }

    if response.success?
      status = SensorStatus.from_json(response.body.not_nil!)

      time = Time.utc.to_unix
      mod_id = module_id
      self[:humidity] = humidity = Interface::Sensor::Detail.new(SensorType::Humidity, status.humidity.to_f, time, @mac, "humidity", "Humidity", module_id: mod_id, binding: "humidity")
      self[:temperature] = temperature = Interface::Sensor::Detail.new(SensorType::AmbientTemp, status.temperature.to_f, time, @mac, "temperature", "Temperature", module_id: mod_id, binding: "temperature")
      self[:presence] = presence = Interface::Sensor::Detail.new(SensorType::Presence, status.person_presence.zero? ? 0.0 : 1.0, time, @mac, "presence", "Person Presence", module_id: mod_id, binding: "presence")
      self[:people] = people = Interface::Sensor::Detail.new(SensorType::PeopleCount, status.detected_persons.to_f, time, @mac, "people", "Detected Persons", module_id: mod_id, binding: "people")
      self[:illuminance] = illuminance = Interface::Sensor::Detail.new(SensorType::Illuminance, status.global_illuminance_lux, time, @mac, "illuminance", "Illuminance", module_id: mod_id, binding: "illuminance")

      self[:presence_zones] = presence_zones = status.person_presence_zone.map_with_index do |value, index|
        Interface::Sensor::Detail.new(SensorType::Presence, value.zero? ? 0.0 : 1.0, time, @mac, "presence-#{index}", "Person Presence in Zone#{index}")
      end
      self[:people_zones] = people_zones = status.detected_persons_zone.map_with_index do |value, index|
        Interface::Sensor::Detail.new(SensorType::PeopleCount, value.to_f, time, @mac, "people-#{index}", "Detected People in Zone#{index}")
      end
      self[:illuminance_zones] = illuminance_zones = status.lux_zone.map_with_index do |value, index|
        Interface::Sensor::Detail.new(SensorType::Illuminance, value, time, @mac, "illuminance-#{index}", "Illuminance in Zone#{index}")
      end

      @state = {
        humidity:    humidity,
        temperature: temperature,
        presence:    presence,
        people:      people,
        illuminance: illuminance,

        presence_zones:    presence_zones,
        people_zones:      people_zones,
        illuminance_zones: illuminance_zones,
      }

      status
    else
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  class SensorStatus
    include JSON::Serializable

    @[JSON::Field(key: "AppVersion")]
    property app_version : String

    @[JSON::Field(key: "FpgaVersion")]
    property fpga_version : String

    @[JSON::Field(key: "KnxSapNumber")]
    property knx_sap_number : String

    @[JSON::Field(key: "KnxVersion")]
    property knx_version : String

    @[JSON::Field(key: "KnxAddr")]
    property knx_address : String

    @[JSON::Field(key: "GitRevision")]
    property git_revision : String

    @[JSON::Field(key: "ModelName")]
    property model_name : String

    @[JSON::Field(key: "FrameProcessingTimeMs")]
    property frame_processing_time_ms : Int32

    @[JSON::Field(key: "AverageFps5")]
    property average_fps5 : Float64

    @[JSON::Field(key: "AverageFps50")]
    property average_fps50 : Float64

    @[JSON::Field(key: "RunningTimeHHMMSS")]
    property running_time : String

    @[JSON::Field(key: "UptimeHHMMSS")]
    property uptime : String

    @[JSON::Field(key: "IrLedOn")]
    property ir_led_on : Int32

    @[JSON::Field(key: "DetectedPersons")]
    property detected_persons : Int32

    @[JSON::Field(key: "PersonPresence")]
    property person_presence : Int32

    @[JSON::Field(key: "DetectedPersonsZone")]
    property detected_persons_zone : Array(Int32)

    @[JSON::Field(key: "PersonPresenceZone")]
    property person_presence_zone : Array(Int32)

    @[JSON::Field(key: "DetectionZonesPresent")]
    property detection_zones_present : Int32

    @[JSON::Field(key: "GlobalIlluminanceLux")]
    property global_illuminance_lux : Float64

    @[JSON::Field(key: "LuxZone")]
    property lux_zone : Array(Float64)

    @[JSON::Field(key: "GlobalLightValue")]
    property global_light_value : Int32

    @[JSON::Field(key: "ArmsensorCpuUsage")]
    property arm_sensor_cpu_usage : String

    @[JSON::Field(key: "WebServerCpuUsage")]
    property web_server_cpu_usage : String

    @[JSON::Field(key: "Temperature")]
    property temperature : String

    @[JSON::Field(key: "Humidity")]
    property humidity : String

    @[JSON::Field(key: "KnxDetected")]
    property knx_detected : String

    @[JSON::Field(key: "KnxProgramMode")]
    property knx_program_mode : String

    @[JSON::Field(key: "KnxLedState")]
    property knx_led_state : String
    property final : String
  end
end
