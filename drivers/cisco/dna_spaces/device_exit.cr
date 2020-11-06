require "./events"

class DeviceExit
  include JSON::Serializable

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "visitDurationMinutes")]
  getter visit_duration_minutes : Int32
end
