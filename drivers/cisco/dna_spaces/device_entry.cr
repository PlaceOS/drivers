require "./events"

class Cisco::DNASpaces::DeviceEntry
  include JSON::Serializable

  getter device : Device
  getter location : Location

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "entryTimestamp")]
  getter entry_timestamp : Int64

  @[JSON::Field(key: "entryDateTime")]
  getter entry_datetime : String

  @[JSON::Field(key: "timeZone")]
  getter time_zone : String

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "daysSinceLastVisit")]
  getter days_sinc_last_visit : Int32
end
