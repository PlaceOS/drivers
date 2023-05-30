require "json"

module Vecos
  struct LockerGroupStatus
    include JSON::Serializable

    @[JSON::Field(key: "LockerGroupId")]
    getter locker_group_id : String

    @[JSON::Field(key: "LockerGroupName")]
    getter locker_group_name : String

    @[JSON::Field(key: "UsableLockers")]
    getter usable_lockers : Int32

    @[JSON::Field(key: "UnusableLockers")]
    getter unusable_lockers : Int32

    @[JSON::Field(key: "PublicLockers")]
    getter public_lockers : Int32

    @[JSON::Field(key: "AvailableDynamicLockers")]
    getter available_dynamic_lockers : Int32

    @[JSON::Field(key: "AllocatedDynamicLockers")]
    getter allocated_dynamic_lockers : Int32

    @[JSON::Field(key: "BlockedAllocatedDynamicLockers")]
    getter blocked_allocated_dynamic_lockers : Int32

    @[JSON::Field(key: "BlockedUnallocatedDynamicLockers")]
    getter blocked_unallocated_dynamic_lockers : Int32

    @[JSON::Field(key: "AvailableStaticLockers")]
    getter available_static_lockers : Int32

    @[JSON::Field(key: "AllocatedStaticLockers")]
    getter allocated_static_lockers : Int32

    @[JSON::Field(key: "BlockedAllocatedStaticLockers")]
    getter blocked_allocated_static_lockers : Int32

    @[JSON::Field(key: "BlockedUnallocatedStaticLockers")]
    getter blocked_unallocated_static_lockers : Int32
  end
end
