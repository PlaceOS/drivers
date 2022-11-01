require "./events"

class Cisco::DNASpaces::UserPresence
  include JSON::Serializable

  class User
    include JSON::Serializable

    @[JSON::Field(key: "userId")]
    getter user_id : String

    @[JSON::Field(key: "deviceIds")]
    getter device_ids : Array(String)
    getter tags : Array(String) = [] of String
    getter mobile : String?
    getter email : String?
    getter gender : String?

    @[JSON::Field(key: "firstName")]
    getter first_name : String?

    @[JSON::Field(key: "lastName")]
    getter last_name : String?

    @[JSON::Field(key: "postalCode")]
    getter postal_code : String?

    # otherFields
    # socialNetworkInfo
  end

  class UserCount
    include JSON::Serializable

    @[JSON::Field(key: "usersWithUserId")]
    getter users_with_user_id : Int64

    @[JSON::Field(key: "usersWithoutUserId")]
    getter users_without_user_id : Int64

    @[JSON::Field(key: "totalUsers")]
    getter total_users : Int64
  end

  @[JSON::Field(key: "presenceEventType")]
  getter presence_event_type : String

  @[JSON::Field(key: "wasInActive")]
  getter was_in_active : Bool

  getter user : User
  getter location : Location

  @[JSON::Field(key: "rawUserId")]
  getter raw_user_id : String

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "entryTimestamp")]
  getter entry_timestamp : Int64

  @[JSON::Field(key: "entryDateTime")]
  getter entry_datetime : String

  @[JSON::Field(key: "exitTimestamp")]
  getter exit_timestamp : Int64

  @[JSON::Field(key: "exitDateTime")]
  getter exit_datetime : String

  @[JSON::Field(key: "visitDurationMinutes")]
  getter visit_duration_minutes : Int32

  @[JSON::Field(key: "timeZone")]
  getter time_zone : String

  @[JSON::Field(key: "activeUsersCount")]
  getter active_users_count : UserCount

  @[JSON::Field(key: "inActiveUsersCount")]
  getter inactive_users_count : UserCount
end
