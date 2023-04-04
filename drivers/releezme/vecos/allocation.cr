require "json"

module Releezme
  struct Allocation
    include JSON::Serializable

    # This is the internal user_id - not the user email etc
    @[JSON::Field(key: "UserId")]
    getter user_id : String

    @[JSON::Field(key: "LockerId")]
    getter locker_id : String

    @[JSON::Field(key: "SelfReleaseAllowed")]
    getter? self_releasable : Bool

    @[JSON::Field(key: "DynamicAllocated")]
    getter? dynamically_allocated : Bool

    @[JSON::Field(key: "StartDateTimeUtc")]
    getter starting : Time

    @[JSON::Field(key: "ExpiresDateTimeUtc")]
    getter expiring : Time

    @[JSON::Field(key: "SharedToUser")]
    getter? shared_to_user : Bool

    @[JSON::Field(key: "AllocatedForPackage")]
    getter? allocated_for_package : Bool

    @[JSON::Field(key: "AllocatedByLockerActionOnRelease")]
    getter? allocated_by_locker_action_on_release : Bool
  end
end
