require "json"

module Vecos
  struct Locker
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "LockerGroupId")]
    getter locker_group_id : String

    @[JSON::Field(key: "LockerBankId")]
    getter locker_bank_id : String

    @[JSON::Field(key: "LockerBrickId")]
    getter locker_brick_id : String

    @[JSON::Field(key: "Blocked")]
    getter blocked : Bool

    @[JSON::Field(key: "IsUsable")]
    getter is_usable : Bool

    @[JSON::Field(key: "IsDetected")]
    getter is_detected : Bool

    @[JSON::Field(key: "FullDoorNumber")]
    getter full_door_number : String

    @[JSON::Field(key: "DoorNumberPrefix")]
    getter door_number_prefix : String

    @[JSON::Field(key: "DoorNumber")]
    getter door_number : Int32

    @[JSON::Field(key: "SelfReleaseAllowed")]
    getter self_release_allowed : Bool?

    @[JSON::Field(key: "DynamicAllocated")]
    getter dynamic_allocated : Bool?

    @[JSON::Field(key: "OpenTime")]
    getter open_time : Int32

    @[JSON::Field(key: "NrOfAllocations")]
    getter number_of_allocations : Int32

    @[JSON::Field(key: "SharedToUser")]
    getter shared_to_user : Bool?

    @[JSON::Field(key: "IsShared")]
    getter is_shared : Bool?

    @[JSON::Field(key: "IsShareable")]
    getter is_shareable : Bool?

    @[JSON::Field(key: "SequenceNumber")]
    getter sequence_number : Int32

    @[JSON::Field(key: "StartDateTimeUtc")]
    getter start_date_time_utc : String?

    @[JSON::Field(key: "NumberOfDigitsForDoorNumber")]
    getter number_of_digits_for_door_number : Int32
  end
end
