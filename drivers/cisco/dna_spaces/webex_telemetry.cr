require "./events"
require "./location"

# https://partners.dnaspaces.io/docs/v1/basic/c-dnas-firehose-api-references.html#!c-firehose-proto-buf-doc.html
class Cisco::DNASpaces::WebexDeviceInfo
  include JSON::Serializable

  @[JSON::Field(key: "deviceId")]
  getter id : String

  @[JSON::Field(key: "macAddress")]
  property mac_address : String

  @[JSON::Field(key: "ipAddress")]
  getter ip_address : String

  # these fields are named to be compatible with the IoT field names
  @[JSON::Field(key: "product")]
  getter type : String

  @[JSON::Field(key: "displayName")]
  getter device_name : String

  @[JSON::Field(key: "serialNumber")]
  getter serial_number : String

  @[JSON::Field(key: "softwareVersion")]
  getter software_version : String

  @[JSON::Field(key: "workspaceId")]
  getter workspace_id : String

  @[JSON::Field(key: "orgId")]
  getter org_id : String
end

struct Cisco::DNASpaces::WebexTelemetry
  include JSON::Serializable

  getter presence : Bool?

  @[JSON::Field(key: "peopleCount")]
  getter count : Int32?

  @[JSON::Field(key: "soundLevel")]
  getter sound_level : Float64?

  @[JSON::Field(key: "airQuality")]
  getter air_quality : Float64?

  @[JSON::Field(key: "ambientTemp")]
  getter ambient_temp : Float64?

  @[JSON::Field(key: "ambientNoise")]
  getter ambient_noise : Float64?

  @[JSON::Field(key: "relativeHumidity")]
  getter relative_humidity : Float64?
end

class Cisco::DNASpaces::WebexTelemetryUpdate
  include JSON::Serializable

  @[JSON::Field(key: "deviceInfo")]
  property device : WebexDeviceInfo
  property location : Location

  @[JSON::Field(ignore_serialize: true)]
  property telemetries : Array(WebexTelemetry) { [] of WebexTelemetry }

  getter people_count : Int32 do
    telemetries.compact_map(&.count).first? || 0
  end

  getter presence : Bool do
    telemetries.compact_map(&.presence).first? || (people_count > 0)
  end

  getter humidity : Float64? do
    telemetries.compact_map(&.relative_humidity).first?
  end

  getter air_quality : Float64? do
    telemetries.compact_map(&.air_quality).first?
  end

  getter temperature : Float64? do
    telemetries.compact_map(&.ambient_temp).first?
  end

  getter ambient_noise : Float64? do
    telemetries.compact_map(&.ambient_noise).first?
  end

  def update_telemetry
    telemetries.each do |telemetry|
      if !telemetry.presence.nil?
        @presence = telemetry.presence
        next
      end

      if count = telemetry.count
        @people_count = count
        next
      end

      if float = telemetry.relative_humidity
        @humidity = float
        next
      end

      if float = telemetry.air_quality
        @air_quality = float
        next
      end

      if float = telemetry.ambient_temp
        @temperature = float
        next
      end

      if float = telemetry.ambient_noise
        @ambient_noise = float
      end
    end
  end

  def binding(type : SensorType, mac : String)
    case type
    when .presence?
      "#{mac}->presence"
    when .humidity?
      "#{mac}->humidity"
    when .air_quality?
      "#{mac}->air_quality"
    when .people_count?
      "#{mac}->people_count"
    when .temperature?
      "#{mac}->temperature"
    when .sound_pressure?
      "#{mac}->ambient_noise"
    end
  end

  @[JSON::Field(ignore: true)]
  property last_seen : Int64 do
    Time.utc.to_unix_ms
  end

  @[JSON::Field(ignore: true)]
  property map_id : String = ""

  def visit_id
    nil
  end

  def raw_user_id : String
    ""
  end

  @[JSON::Field(ignore: true)]
  @location_mappings : Hash(String, String)? = nil

  # Ensure we only process these once
  def location_mappings : Hash(String, String)
    if mappings = @location_mappings
      mappings
    else
      mappings = location.details
      @location_mappings = mappings
      mappings
    end
  end
end
