require "./events"

# This is triggered from telepresence devices
class Cisco::DNASpaces::PeopleCountUpdate
  include JSON::Serializable

  @[JSON::Field(key: "tpDeviceId")]
  getter tp_device_id : String
  getter location : Location
  getter presence : Bool

  @[JSON::Field(key: "peopleCount")]
  getter people_count : Int32

  @[JSON::Field(key: "standbyState")]
  getter standby_state : Int32

  @[JSON::Field(key: "ambientNoise")]
  getter ambient_noise : Int32

  @[JSON::Field(key: "drynessScore")]
  getter dryness_score : Int32

  @[JSON::Field(key: "activeCalls")]
  getter active_calls : Int32

  @[JSON::Field(key: "presentationState")]
  getter presentation_state : Int32

  @[JSON::Field(key: "timeStamp")]
  getter timestamp : Int64
end
