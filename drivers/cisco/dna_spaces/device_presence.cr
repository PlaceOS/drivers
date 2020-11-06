require "./events"

class DevicePresence
  include JSON::Serializable

  @[JSON::Field(key: "presenceEventType")]
  getter presence_event_type : String
end
