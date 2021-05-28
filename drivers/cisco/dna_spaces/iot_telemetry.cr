require "./events"
require "./location"

class Cisco::DNASpaces::IotDeviceInfo
  include JSON::Serializable

  @[JSON::Field(key: "deviceType")]
  property type : String

  @[JSON::Field(key: "deviceId")]
  property id : String

  @[JSON::Field(key: "deviceMacAddress")]
  property mac_address : String

  @[JSON::Field(key: "deviceName")]
  property device_name : String

  @[JSON::Field(key: "firmwareVersion")]
  property firmware_version : String

  @[JSON::Field(key: "rawDeviceId")]
  property raw_id : String
  property manufacturer : String

  def os
    type
  end
end

class Cisco::DNASpaces::IotPosition
  include JSON::Serializable

  @[JSON::Field(key: "mapId")]
  property map_id : String

  @[JSON::Field(key: "xPos")]
  getter x_pos : Float64

  @[JSON::Field(key: "yPos")]
  getter y_pos : Float64

  @[JSON::Field(key: "confidenceFactor")]
  getter confidence_factor : Float64
  getter latitude : Float64
  getter longitude : Float64

  @[JSON::Field(key: "locationId")]
  property location_id : String

  @[JSON::Field(key: "lastLocatedTime")]
  property time_located : Int64
end

class Cisco::DNASpaces::IotTelemetry
  include JSON::Serializable

  @[JSON::Field(key: "deviceInfo")]
  getter device : IotDeviceInfo

  @[JSON::Field(key: "detectedPosition")]
  getter position : IotPosition

  getter location : Location

  @[JSON::Field(key: "deviceRtcTime")]
  getter device_rtc : Int64

  @[JSON::Field(key: "rawHeader")]
  getter raw_header : Int64

  @[JSON::Field(key: "rawPayload")]
  getter raw_payload : String

  @[JSON::Field(key: "sequenceNum")]
  getter sequence_num : Int64

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

  # make this class quack like a wifi DeviceLocationUpdate
  delegate map_id, to: @position
  delegate latitude, to: @position
  delegate longitude, to: @position
  delegate confidence_factor, to: @position
  delegate x_pos, to: @position
  delegate y_pos, to: @position

  def visit_id
    "unknown for IoT"
  end

  def last_seen
    position.time_located
  end

  def raw_user_id
    ""
  end

  def unc : Float64
    3.0
  end

  def ssid
    "IoT"
  end
end
