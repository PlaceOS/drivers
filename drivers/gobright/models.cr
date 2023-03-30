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

    @[JSON::Field(key: "continuationToken")]
    getter token : String?
  end

  struct Response
    include JSON::Serializable

    @[JSON::Field(key: "meta")]
    getter metadata : Metadata?

    @[JSON::Field(converter: String::RawConverter)]
    getter data : String

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

  struct Space
    include JSON::Serializable

    getter id : String
    getter name : String
    getter amenities : Array(Amenity) = [] of Amenity

    @[JSON::Field(converter: Enum::ValueConverter(::GoBright::SpaceType))]
    getter type : SpaceType

    @[JSON::Field(key: "locationId")]
    getter location_id : String

    @[JSON::Field(key: "ianaTimeZone")]
    getter iana_time_zone : String?
    getter capacity : Int64?

    @[JSON::Field(key: "integrationExternalId")]
    getter integration_external_id : String?

    @[JSON::Field(key: "isBookable")]
    getter is_bookable : Bool?
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
end
