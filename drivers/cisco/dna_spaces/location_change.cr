require "./events"

class LocationChange
  include JSON::Serializable

  @[JSON::Field(key: "changeType")]
  getter change_type : String
end
