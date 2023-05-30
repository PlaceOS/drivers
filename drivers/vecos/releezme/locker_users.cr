require "json"

module Vecos
  struct LockerUsers
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "FirstName")]
    getter first_name : String?

    @[JSON::Field(key: "LastName")]
    getter last_name : String?

    @[JSON::Field(key: "EmailAddress")]
    getter email : String?

    @[JSON::Field(key: "ExternalUserId")]
    getter user_id : String
  end
end
