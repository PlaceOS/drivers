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
end

class Cisco::DNASpaces::WebexTelemetryUpdate
  include JSON::Serializable

  @[JSON::Field(key: "deviceInfo")]
  getter device : WebexDeviceInfo
  getter location : Location
  getter telemetries : Array(WebexTelemetry) { [] of WebexTelemetry }

  @[JSON::Field(ignore: true)]
  getter people_count : Int32 do
    telemetries.compact_map(&.count).first? || 0
  end

  @[JSON::Field(ignore: true)]
  getter presence : Bool do
    telemetries.compact_map(&.presence).first? || (people_count > 0)
  end

  @[JSON::Field(ignore: true)]
  property last_seen : Int64 do
    Time.utc.to_unix_ms
  end

  def has_position?
    true
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

  # these are unused but here for compilation reasons
  def humidity
    nil
  end

  def air_quality
    nil
  end

  def temperature
    nil
  end

  def ambient_noise
    nil
  end
end
