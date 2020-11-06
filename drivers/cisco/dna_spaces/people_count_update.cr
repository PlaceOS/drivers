require "./events"

class PeopleCountUpdate
  include JSON::Serializable

  @[JSON::Field(key: "tpDeviceId")]
  getter tp_device_id : String
end
