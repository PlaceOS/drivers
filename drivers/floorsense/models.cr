require "json"

# Floorsense Data Models
module Floorsense
  class AuthResponse
    include JSON::Serializable

    class Info
      include JSON::Serializable

      property token : String
      property sessionid : String
    end

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool
    property message : String?

    # Returned on failure
    property code : Int32?

    # Returned on success
    property info : Info?
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

  class DesksResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(DeskStatus)?
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

  class LocateResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(UserLocation)?
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

  class FloorsResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(Floor)?
  end

  class BookingStatus
    include JSON::Serializable

    property key : String
    property uid : String

    @[JSON::Field(key: "bktype")]
    property booking_type : String

    @[JSON::Field(key: "bkid")]
    property booking_id : String

    property created : Int64
    property start : Int64
    property finish : Int64

    property conftime : Int64?
    property confmethod : Int32?
    property confexpiry : Int64?

    property cid : Int32
    property planid : Int32
    property groupid : Int32

    property released : Int32
    property releasecode : Int32
    property active : Bool
    property confirmed : Bool
    property privacy : Bool

    # not included in the responses but we will merge this
    property user : User?
  end

  class BookingsResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success (desk => bookings)
    property info : Hash(String, Array(BookingStatus))?
  end

  class User
    include JSON::Serializable

    property uid : String
    property email : String?
    property name : String
    property desc : String?
    property lastlogin : Int64?
    property expiry : Int64?
  end

  class UserResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : User?
  end

  class UsersResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(User)?
  end
end
