require "json"

module Vecos
  struct Booking
    include JSON::Serializable

    @[JSON::Field(key: "BookingId")]
    getter id : String

    @[JSON::Field(key: "LockerId")]
    getter locker_id : String

    @[JSON::Field(key: "LockerBankId")]
    getter locker_bank_id : String

    @[JSON::Field(key: "LockerGroupId")]
    getter locker_group_id : String

    @[JSON::Field(key: "FullDoorNumber")]
    getter full_door_number : String

    @[JSON::Field(key: "StartDateTimeUtc")]
    getter starting : Time

    @[JSON::Field(key: "EndDateTimeUtc")]
    getter ending : Time
  end
end
