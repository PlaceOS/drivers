require "json"

module GoBright
  struct Metadata
    include JSON::Serializable

    @[JSON::Field(key: "statusCode")]
    getter status_code : Int32?

    @[JSON::Field(key: "message")]
    getter message : String?

    @[JSON::Field(key: "validationErrors")]
    getter validation_errors : Array(Hash(String, String))?
  end

  struct Paging
    include JSON::Serializable

    @[JSON::Field(key: "totalCount")]
    getter total : Int32

    @[JSON::Field(key: "continuationToken")]
    getter token : String?
  end

  struct Response
    include JSON::Serializable

    @[JSON::Field(key: "meta")]
    getter metadata : Metadata?

    @[JSON::Field(converter: String::RawConverter)]
    getter data : String?

    @[JSON::Field(converter: String::RawConverter)]
    getter items : String?

    @[JSON::Field(key: "paging")]
    getter paging : Paging?
  end

  # pagingTake == 100
  # include=spaces,attendees
  #
  # code 429 - wait for `RateLimit-Reset` time before making another request
  # RateLimit-Limit header is total count
  # RateLimit-Remaining header is requests remaining
  # RateLimit-Reset header is seconds until reset

  struct DeskPeriod
    include JSON::Serializable

    @[JSON::Field(key: "mode")]
    getter mode : Int64?

    @[JSON::Field(key: "workingMode")]
    getter working_mode : Int64?

    @[JSON::Field(key: "startOfDay")]
    getter start_of_day : String?

    @[JSON::Field(key: "middleOfDay")]
    getter middle_of_day : String?

    @[JSON::Field(key: "endOfDay")]
    getter end_of_day : String?
  end

  struct ParkingPeriod
    include JSON::Serializable

    @[JSON::Field(key: "mode")]
    getter mode : Int64?

    @[JSON::Field(key: "workingMode")]
    getter working_mode : Int64?

    @[JSON::Field(key: "startOfDay")]
    getter start_of_day : String?

    @[JSON::Field(key: "middleOfDay")]
    getter middle_of_day : String?

    @[JSON::Field(key: "endOfDay")]
    getter end_of_day : String?
  end

  struct Amenity
    include JSON::Serializable

    getter id : String
    getter description : String?
    getter icon : String?
    getter order : Int32?

    @[JSON::Field(key: "availableForRoom")]
    getter available_for_room : Bool?

    @[JSON::Field(key: "availableForDesk")]
    getter available_for_desk : Bool?

    @[JSON::Field(key: "availableForParking")]
    getter available_for_parking : Bool?
  end

  struct Location
    include JSON::Serializable

    getter id : String

    @[JSON::Field(key: "oldId")]
    getter old_id : Int64?

    @[JSON::Field(key: "parentId")]
    getter parent_id : String?

    getter name : String

    @[JSON::Field(key: "nameIndented")]
    getter name_indented : String?

    @[JSON::Field(key: "order")]
    getter order : Int64?

    @[JSON::Field(key: "level")]
    getter level : Int64?

    @[JSON::Field(key: "fullPath")]
    getter full_path : String?

    @[JSON::Field(key: "ianaTimeZone")]
    getter iana_time_zone : String?

    @[JSON::Field(key: "visitorKioskEnabled")]
    getter visitor_kiosk_enabled : Bool?

    @[JSON::Field(key: "imageId")]
    getter image_id : String?

    @[JSON::Field(key: "bookingDeskPeriods")]
    getter booking_desk_periods : DeskPeriod?

    @[JSON::Field(key: "bookingParkingPeriods")]
    getter booking_parking_periods : ParkingPeriod?
  end

  enum SpaceType
    Room         = 0
    Desk         = 1
    CombinedRoom = 2
    Parking      = 3
  end

  class Space
    include JSON::Serializable

    getter id : String
    getter name : String
    getter amenities : Array(Amenity) = [] of Amenity

    @[JSON::Field(converter: Enum::ValueConverter(::GoBright::SpaceType))]
    getter type : SpaceType?

    @[JSON::Field(key: "locationId")]
    getter location_id : String?

    @[JSON::Field(key: "ianaTimeZone")]
    getter iana_time_zone : String?
    getter capacity : Int64?

    @[JSON::Field(key: "integrationExternalId")]
    getter integration_external_id : String?

    @[JSON::Field(key: "isBookable")]
    getter is_bookable : Bool?

    @[JSON::Field(ignore: true)]
    property? occupied : Bool = false
  end

  struct Occupancy
    include JSON::Serializable

    @[JSON::Field(key: "spaceId")]
    getter id : String?

    @[JSON::Field(key: "occupationDetected")]
    getter? occupied : Bool?
  end

  struct AccessToken
    include JSON::Serializable

    getter access_token : String
    getter expires_in : Int32

    def expires_at : Time
      expires_in.seconds.from_now
    end
  end

  enum ApprovalState
    Inactive      = 0
    NeedsApproval = 1
    Approved      = 2
    Rejected      = 3
  end

  enum BookingType
    BookingOnRoom    = 0
    ServiceOnly      = 1
    BookingOnDesk    = 2
    BookingAsTeam    = 3
    BookingOnParking = 4
  end

  struct Attendee
    include JSON::Serializable

    @[JSON::Field(key: "emailAddress")]
    property email_address : String?
    property name : String?
  end

  struct Occurrence
    include JSON::Serializable

    property id : String

    @[JSON::Field(key: "composedId")]
    property composed_id : String

    @[JSON::Field(key: "bookingType", converter: Enum::ValueConverter(::GoBright::BookingType))]
    property booking_type : BookingType

    @[JSON::Field(key: "intentionType")]
    property intention_type : Int32?

    @[JSON::Field(key: "recurrenceType")]
    property recurrence_type : Int32?

    @[JSON::Field(key: "approvalState", converter: Enum::ValueConverter(::GoBright::ApprovalState))]
    property approval_state : ApprovalState?

    @[JSON::Field(key: "isAnonymouslyBooked")]
    property is_anonymously_booked : Bool?

    @[JSON::Field(key: "licensePlate")]
    property license_plate : String?

    @[JSON::Field(key: "start")]
    property start_date : Time

    @[JSON::Field(key: "end")]
    property end_date : Time
    property subject : String?
    property organizer : Attendee?
    property spaces : Array(Space) = [] of Space
    property attendees : Array(Attendee) = [] of Attendee

    @[JSON::Field(key: "attendeeAmount")]
    property attendee_amount : Int32?

    @[JSON::Field(key: "confirmationActive")]
    property confirmation_active : Bool?

    @[JSON::Field(key: "confirmationWindowStart")]
    property confirmation_window_start : String?

    @[JSON::Field(key: "confirmationWindowEnd")]
    property confirmation_window_end : String?

    @[JSON::Field(ignore: true)]
    property! zone_id : String

    @[JSON::Field(ignore: true)]
    property! matched_space : Space
  end
end
