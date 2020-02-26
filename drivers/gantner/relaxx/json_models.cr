require "json"

module Gantner; end
module Gantner::Relaxx
  class Result
    include JSON::Serializable

    @[JSON::Field(key: "Successful")]
    property successful : Bool

    @[JSON::Field(key: "Cancelled")]
    property cancelled : Bool

    @[JSON::Field(key: "ResultText")]
    property text : String

    @[JSON::Field(key: "ResultCode")]
    property code : Int32
  end

  enum LockerState
    Unknown = 0
    Disabled
    Free
    InUse
    Locked
    Alarmed
    InUseExpired
    Conflict
  end

  enum LockerMode
    Unknown = 0
    NotExisting
    FreeLocker
    PersonalLocker
    ReservableLocker
    DynamicLocker
  end

  class Locker
    include JSON::Serializable

    @[JSON::Field(key: "RecordId")]
    property id : String

    @[JSON::Field(key: "LockerGroupId")]
    property group_id : String

    @[JSON::Field(key: "LockerGroupName")]
    property group_name : String

    @[JSON::Field(key: "Number")]
    property locker_number : String

    @[JSON::Field(key: "Address")]
    property address : Int32

    @[JSON::Field(key: "State")]
    property state : Int32

    @[JSON::Field(key: "LockerMode")]
    property mode : Int32

    # Is it a personal locker or a free (no cost?) locker?
    @[JSON::Field(key: "IsFreeLocker")]
    property is_free : Bool

    @[JSON::Field(key: "IsDeleted")]
    property is_deleted : Bool

    @[JSON::Field(key: "IsExisting")]
    property is_existing : Bool

    @[JSON::Field(key: "LastClosedTime")]
    property last_closed : String

    @[JSON::Field(key: "CardUIDInUse")]
    property card_id : String

    def locker_state
      LockerState.from_value self.state
    end

    def locker_mode
      LockerMode.from_value self.mode
    end
  end

  enum LockerEvent
    Opened = 0
    Closed
    Enabled
    Disabled
    Alarmed
  end

  class LockerNotification
    include JSON::Serializable

    @[JSON::Field(key: "Event")]
    property event : Int32

    @[JSON::Field(key: "PreviousState")]
    property prev_state : Int32

    @[JSON::Field(key: "EventDateTime")]
    property time : String

    @[JSON::Field(key: "Locker")]
    property locker : Locker

    @[JSON::Field(key: "LockerAreaId")]
    property area_id : String

    @[JSON::Field(key: "LockerAreaName")]
    property area_name : String

    @[JSON::Field(key: "WithMasterCard")]
    property group_name : Bool

    @[JSON::Field(key: "WithSystemCard")]
    property group_name : Bool

    @[JSON::Field(key: "WithMaintenanceCard")]
    property group_name : Bool

    def locker_state
      self.locker.state
    end

    def previous_state
      LockerState.from_value self.prev_state
    end
  end
end
