require "./events"

class ProfileUpdate
  include JSON::Serializable

  @[JSON::Field(key: "deviceId")]
  getter device_id : String

  @[JSON::Field(key: "userId")]
  getter user_id : String
end
