require "./events"

class Cisco::DNASpaces::DevicePresence
  include JSON::Serializable

  @[JSON::Field(key: "presenceEventType")]
  getter presence_event_type : String

  @[JSON::Field(key: "wasInActive")]
  getter was_in_active : Bool
  getter device : Device
  getter location : Location

  getter ssid : String

  @[JSON::Field(key: "rawUserId")]
  getter raw_user_id : String

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "daysSinceLastVisit")]
  getter days_since_last_visit : Int32

  @[JSON::Field(key: "entryTimestamp")]
  getter entry_timestamp : Int64

  @[JSON::Field(key: "entryDateTime")]
  getter entry_datetime : String

  @[JSON::Field(key: "exitTimestamp")]
  getter exit_timestamp : Int64

  @[JSON::Field(key: "exitDateTime")]
  getter exit_date_time : String

  @[JSON::Field(key: "visitDurationMinutes")]
  getter visit_duration_minutes : Int32

  @[JSON::Field(key: "timeZone")]
  getter time_zone : String

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "visitClassification")]
  getter visit_classification : String

  @[JSON::Field(key: "activeDevicesCount")]
  getter active_devices_count : Int32

  @[JSON::Field(key: "inActiveDevicesCount")]
  getter inactive_devices_count : Int32
end
