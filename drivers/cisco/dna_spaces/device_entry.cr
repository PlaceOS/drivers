require "./events"

class DeviceEntry
  include JSON::Serializable

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "daysSinceLastVisit")]
  getter days_since_last_visit : Int32
end
