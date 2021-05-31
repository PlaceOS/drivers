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

class Cisco::DNASpaces::TpData
  include JSON::Serializable

  @[JSON::Field(key: "peopleCount")]
  property people_count : Int32

  @[JSON::Field(key: "standbyState")]
  property standby_state : Int32

  @[JSON::Field(key: "ambientNoise")]
  property ambient_noise : Int32

  @[JSON::Field(key: "drynessScore")]
  property dryness_score : Int32

  @[JSON::Field(key: "activeCalls")]
  property active_calls : Int32

  @[JSON::Field(key: "presentationState")]
  property presentation_state : Int32

  @[JSON::Field(key: "timeStamp")]
  property time_stamp : Int64

  @[JSON::Field(key: "airQualityIndex")]
  property air_quality_index : Float64

  @[JSON::Field(key: "temperatureInCelsius")]
  property temperature_in_celsius : Float64

  @[JSON::Field(key: "humidityInPercentage")]
  property humidity_in_percentage : Float64

  getter presence : Bool
end

class Cisco::DNASpaces::IotTelemetry
  include JSON::Serializable

  @[JSON::Field(key: "deviceInfo")]
  getter device : IotDeviceInfo

  @[JSON::Field(key: "detectedPosition")]
  getter detected_position : IotPosition?

  @[JSON::Field(key: "placedPosition")]
  getter placed_position : IotPosition?

  getter location : Location

  @[JSON::Field(key: "deviceRtcTime")]
  getter device_rtc : Int64

  @[JSON::Field(key: "rawHeader")]
  getter raw_header : Int64

  @[JSON::Field(key: "rawPayload")]
  getter raw_payload : String

  @[JSON::Field(key: "sequenceNum")]
  getter sequence_num : Int64

  @[JSON::Field(key: "airQuality")]
  getter air_quality_index : NamedTuple(airQualityIndex: Float64)?

  @[JSON::Field(key: "temperature")]
  getter temperature_celsius : NamedTuple(temperatureInCelsius: Float64)?

  @[JSON::Field(key: "humidity")]
  getter humidity_percent : NamedTuple(humidityInPercentage: Float64)?

  @[JSON::Field(key: "airPressure")]
  getter air_pressure_actual : NamedTuple(pressure: Float64)?

  @[JSON::Field(key: "pirTrigger")]
  getter pir_trigger : NamedTuple(timestamp: Int64)?

  @[JSON::Field(key: "tpData")]
  getter tele_presence_data : TpData?

  def air_quality
    if index = @air_quality_index
      index[:airQualityIndex]
    else
      0.0
    end
  end

  def temperature
    if temp = @temperature_celsius
      temp[:temperatureInCelsius]
    else
      0.0
    end
  end

  def humidity
    if humidity = @humidity_percent
      humidity[:humidityInPercentage]
    else
      0.0
    end
  end

  def air_pressure
    if pressure = @air_pressure_actual
      pressure[:pressure]
    else
      0.0
    end
  end

  def pir_triggered
    if pir_trigger = @pir_trigger
      pir_trigger[:timestamp]
    else
      0_i64
    end
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

  def has_position?
    !!(@detected_position || @placed_position)
  end

  def position : IotPosition
    (@detected_position || @placed_position).not_nil!
  end

  # make this class quack like a wifi DeviceLocationUpdate
  delegate latitude, to: position
  delegate longitude, to: position
  delegate confidence_factor, to: position
  delegate x_pos, to: position
  delegate y_pos, to: position
  delegate map_id, to: position

  def map_id=(id)
    position.map_id = id
  end

  def visit_id
    "unknown for IoT"
  end

  def last_seen
    position.time_located
  end

  def last_seen=(time)
    position.time_located = time
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
