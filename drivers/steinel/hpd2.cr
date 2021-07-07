require "placeos-driver"

class Steinel::HPD2 < PlaceOS::Driver
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

  def on_load
    on_update
  end

  def on_update
    schedule.every(5.seconds) { get_status }
  end

  def get_status
    response = get("/api/sensorstatus.php")

    logger.debug { "received #{response.body}" }

    if response.success?
      SensorStatus.from_json(response.body.not_nil!)
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
