require "json"

module Releezme
  struct LockerGroup
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "LockMode")]
    getter lock_mode : Int32

    @[JSON::Field(key: "LockerBookingFeatureEnabled")]
    getter locker_booking_feature_enabled : Bool

    @[JSON::Field(key: "PostalServiceFeatureEnabled")]
    getter postal_service_feature_enabled : Bool
  end
end
