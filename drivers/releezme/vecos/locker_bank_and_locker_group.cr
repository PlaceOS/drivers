require "./locker_bank"
require "./locker_group"

module Releezme
  struct LockerBankAndLockerGroup
    include JSON::Serializable

    @[JSON::Field(key: "LockerBank")]
    getter locker_bank : LockerBank

    @[JSON::Field(key: "LockerGroup")]
    getter locker_group : LockerGroup
  end
end
