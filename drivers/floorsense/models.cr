require "json"

# Floorsense Data Models
module Floorsense
  # Websocket payloads
  class Payload
    include JSON::Serializable

    use_json_discriminator "type", {
      "event"    => Event,
      "response" => Response,
    }
  end

  class Event < Payload
    getter type : String = "event"
    getter code : Int32
    getter message : String
    getter info : JSON::Any?
  end

  class Response < Payload
    getter type : String = "response"
    getter result : Bool
    getter message : String
    getter info : JSON::Any?

    def info
      @info || JSON.parse("{}")
    end
  end

  class Resp(T)
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : T?
  end

  class AuthInfo
    include JSON::Serializable

    property token : String
    property sessionid : String
  end

  class LockerInfo
    include JSON::Serializable

    property canid : Int32

    @[JSON::Field(key: "bid")]
    property bus_id : Int32

    @[JSON::Field(key: "lid")]
    property locker_id : Int32

    property reserved : Bool
    property status : Int32
    property firmware : String
    property disabled : Bool
    property confirmed : Bool

    property closed : Bool?
    property usbcharger : Bool?
    property usbcharging : Bool?
    property typename : String?
    property uid : String?
    property groupid : Int32?
    property hardware : Int32?
    property type : String?
    property key : String?
    property usbcurrent : Int32?
    property resid : String?

    # not included by default, used by locker mappings
    property! controller_id : Int32
  end

  class LockerBooking
    include JSON::Serializable

    property created : Int64
    property start : Int64
    property finish : Int64

    @[JSON::Field(key: "cid")]
    property controller_id : Int32

    @[JSON::Field(key: "resid")]
    property reservation_id : String

    @[JSON::Field(key: "uid")]
    property user_id : String

    property key : String
    property pin : String
    property restype : String
    property lastopened : Int64
    property released : Int64
    property active : Int32
    property releasecode : Int32

    def released?
      self.active == 1
    end

    # not included in the responses but we will merge this
    property user : User?
  end

  class DeskStatus
    include JSON::Serializable

    property cid : Int32
    property cached : Bool
    property reservable : Bool
    property netid : Int32
    property status : Int32
    property deskid : Int32

    property hwfeat : Int32
    property hardware : String

    @[JSON::Field(converter: Time::EpochConverter)]
    property created : Time
    property key : String
    property occupied : Bool
    property uid : String
    property eui64 : String

    @[JSON::Field(key: "type")]
    property desk_type : String
    property firmware : String
    property features : Int32
    property freq : String
    property groupid : Int32
    property bkid : String
    property planid : Int32
    property reserved : Bool
    property confirmed : Bool
    property privacy : Bool
    property occupiedtime : Int32
  end

  class DeskInfo
    include JSON::Serializable

    property eui64 : String
    property key : String?
    property planid : Int32?

    @[JSON::Field(key: "type")]
    property desk_type : String?
    property typename : String?

    @[JSON::Field(ignore: true)]
    property! controller_id : Int32
  end

  class UserGroup
    include JSON::Serializable

    @[JSON::Field(key: "ugroupid")]
    property id : Int32
    property name : String
    property count : Int32
  end

  class UserLocation
    include JSON::Serializable

    property name : String
    property uid : String

    # Optional properties (when a user is located):

    @[JSON::Field(converter: Time::EpochConverter)]
    property start : Time?

    @[JSON::Field(converter: Time::EpochConverter)]
    property finish : Time?

    property planid : Int32?
    property occupied : Bool?
    property groupid : Int32?
    property key : String?
    property floorname : String?
    property cid : Int32?
    property occupiedtime : Int32?
    property groupname : String?
    property privacy : Bool?
    property confirmed : Bool?
    property active : Bool?
  end

  class Floor
    include JSON::Serializable

    property planid : Int32
    property name : String

    property imgname : String?
    property imgwidth : Int32?
    property imgheight : Int32?

    property location1 : String?
    property location2 : String?
    property location3 : String?
  end

  class BookingStatus
    include JSON::Serializable

    property key : String
    property uid : String

    @[JSON::Field(key: "bktype")]
    property booking_type : String

    @[JSON::Field(key: "bkid")]
    property booking_id : String

    property desc : String?
    property created : Int64
    property start : Int64
    property finish : Int64

    property conftime : Int64?
    property confmethod : Int32?
    property confexpiry : Int64?

    property cid : Int32
    property planid : Int32
    property groupid : Int32

    # Time the booking was released
    property released : Int64
    property releasecode : Int32
    property active : Bool
    property confirmed : Bool
    property privacy : Bool

    # not included in the responses but we will merge this
    property user : User?

    @[JSON::Field(ignore: true)]
    property! place_id : String
  end

  class User
    include JSON::Serializable

    property uid : String
    property email : String?
    property name : String
    property desc : String?
    property lastlogin : Int64?
    property expiry : Int64?
    property reslimit : Int64?
    property pin : Int64?
    property ugroupid : Int64?
    property uidtoken : String?
    property extid : String?
    property usertype : String?
    property desc : String?
    property privacy : String?
  end

  class LogEntry
    include JSON::Serializable

    property eventid : Int64

    # this is the locker or table name
    property key : String

    # the event code
    property code : Int32

    # booking id
    property bkid : String

    # Possibly includes the booking information
    # not required as we need to grab the user information anyway
    # property extra : JSON::Any?

    property eventtime : Int64
  end

  class RFID
    include JSON::Serializable

    property csn : String
    property uid : String
    property desc : String?
  end

  class ControllerInfo
    include JSON::Serializable

    @[JSON::Field(key: "cid")]
    property controller_id : Int32

    property online : Bool
    property lockers : Bool
    property desks : Bool

    property id : String
    property name : String
    property location1 : String
    property location2 : String
    property location3 : String
    property location4 : String

    property mode : String
  end

  class Voucher
    include JSON::Serializable

    property lastuse : Int64
    property email : String

    @[JSON::Field(key: "vid")]
    property voucher_id : String

    @[JSON::Field(key: "key")]
    property locker_key : String

    @[JSON::Field(key: "cid")]
    property controller_id : String

    @[JSON::Field(key: "resid")]
    property reservation_id : String

    property pin : String
    property created : Int64
    property release : Bool
    property duration : Int64
    property expired : Int64
    property usecount : Int64
    property maxuse : Int64
    property restype : String
    property notified : Int64
    property validfrom : Int64
    property validto : Int64

    property unlock : Bool
    property template : String
    property name : String
    property notes : String
    property cardswipe : Bool

    @[JSON::Field(key: "uid")]
    property user_id : String
    property uri : String
  end
end
