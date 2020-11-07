require "./events"

class Cisco::DNASpaces::DeviceLocationUpdate
  include JSON::Serializable

  getter device : Device
  getter location : Location

  getter ssid : String

  @[JSON::Field(key: "rawUserId")]
  getter raw_user_id : String

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "lastSeen")]
  getter last_seen : Int64

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "mapId")]
  getter map_id : String

  @[JSON::Field(key: "xPos")]
  getter x_pos : Float64

  @[JSON::Field(key: "yPos")]
  getter y_pos : Float64

  @[JSON::Field(key: "confidenceFactor")]
  getter confidence_factor : Float64
  getter latitude : Float64
  getter longitude : Float64
end
