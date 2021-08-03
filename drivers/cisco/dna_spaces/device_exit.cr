require "./events"

class Cisco::DNASpaces::DeviceExit
  include JSON::Serializable

  getter device : Device
  getter location : Location

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "visitDurationMinutes")]
  getter visit_duration_minutes : Int32

  @[JSON::Field(key: "visitDurationMinutes")]
  getter visit_duration_minutes : Int32

  @[JSON::Field(key: "entryTimestamp")]
  getter entry_timestamp : Int64

  @[JSON::Field(key: "entryDateTime")]
  getter entry_datetime : String

  @[JSON::Field(key: "exitTimestamp")]
  getter exit_timestamp : Int64

  @[JSON::Field(key: "exitDateTime")]
  getter exit_datetime : String

  @[JSON::Field(key: "timeZone")]
  getter time_zone : String

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "visitClassification")]
  getter visit_classification : String
end
