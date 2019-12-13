require "json"

# OfficeRnD Data Models
module OfficeRnd
  abstract struct Data
    include JSON::Serializable
  end

  struct TokenResponse < Data
    include JSON::Serializable
    property access_token : String
    property token_type : String
    property expires_in : Int32
    property scope : String
  end

  struct Office < Data
    @[JSON::Field(key: "_id")]
    getter id : String
    getter name : String
    getter country : String?
    getter state : String?
    getter city : String?
    getter address : String?
    getter timezone : String?
    getter image : String?
    @[JSON::Field(key: "isOpen")]
    getter is_open : Bool?
  end

  struct BookingTime < Data
    @[JSON::Field(key: "dateTime")]
    getter time : Time

    def initialize(@time : Time); end
  end

  struct Fee < Data
    getter name : String
    getter price : Int32
    getter quantity : Int32 = 1
    getter date : Time
    @[JSON::Field(key: "team")]
    getter team_id : String?
    @[JSON::Field(key: "office")]
    getter office_id : String
    @[JSON::Field(key: "member")]
    getter member_id : String?
    @[JSON::Field(key: "plan")]
    getter plan_id : String?
    getter refundable : Bool?
    @[JSON::Field(key: "billInAdvance")]
    getter bill_in_advance : Bool?
    @[JSON::Field(key: "isPersonal")]
    getter is_personal : Bool?
  end

  struct BookingFee < Data
    getter date : Time
    getter fee : Fee?
    @[JSON::Field(key: "extraFees")]
    getter extra_fees : Array(JSON::Any?)
    getter credits : Array(Credit)
  end

  struct Booking < Data
    @[JSON::Field(key: "start")]
    getter booking_start : BookingTime
    @[JSON::Field(key: "end")]
    getter booking_end : BookingTime
    getter timezone : String = "Australia/Sydney"
    getter source : String?
    getter summary : String?
    @[JSON::Field(key: "resourceId")]
    getter resource_id : String
    @[JSON::Field(key: "plan")]
    getter plan_id : String = ""
    @[JSON::Field(key: "team")]
    getter team_id : String?
    @[JSON::Field(key: "member")]
    getter member_id : String?
    getter description : String?
    getter tentative : Bool?
    getter free : Bool?
    getter fees : Array(::OfficeRnd::BookingFee) = [] of ::OfficeRnd::BookingFee
    getter extras : JSON::Any = JSON::Any.new("")

    def initialize(
      @resource_id : String,
      booking_start : Time,
      booking_end : Time,
      @summary : String? = nil,
      @team_id : String? = nil,
      @member_id : String? = nil,
      @description : String? = nil,
      @tentative : Bool? = nil,
      @free : Bool? = nil
    )
      unless @member_id || @team_id
        raise "Booking requires at least one of team_id or member_id"
      end
      @booking_start = BookingTime.new(booking_start)
      @booking_end = BookingTime.new(booking_end)
    end
  end

  struct Credit < Data
    getter count : Int32
    getter credit : String
  end

  struct Rate < Data
    @[JSON::Field(key: "_id")]
    getter id : String
    getter name : String
    getter price : Int32
    @[JSON::Field(key: "cancellationPolicy")]
    getter cancellation_policy : CancellationPolicy
    getter extras : Array(Extra)
    @[JSON::Field(key: "maxDuration")]
    getter max_duration : Int32

    struct CancellationPolicy < Data
      @[JSON::Field(key: "minimumPeriod")]
      property minimum_period : Int32
    end

    struct Extra < Data
      @[JSON::Field(key: "_id")]
      getter id : String
      getter name : String
      getter price : Int32
    end
  end

  struct Resource < Data
    getter name : String
    @[JSON::Field(key: "rate")]
    getter rate_id : String?
    @[JSON::Field(key: "office")]
    getter office_id : String
    @[JSON::Field(key: "room")]
    getter floor_id : String
    getter type : Type

    MAPPING = {
      Type::MeetingRoom       => "meeting_room",
      Type::PrivateOffices    => "team_room",
      Type::PrivateOfficeDesk => "desk_tr",
      Type::DedicatedDesks    => "desk",
      Type::HotDesks          => "hotdesk",
    }

    enum Type
      MeetingRoom
      PrivateOffices
      PrivateOfficeDesk
      DedicatedDesks
      HotDesks

      def to_s
        Resource::MAPPING[self]
      end

      def to_json(json : JSON::Builder)
        json.string(self.to_s)
      end

      def self.parse(type : String)
        parsed = Resource::MAPPING.key_for?(type)
        raise ArgumentError.new("Unrecognised Resource::Type '#{type}'") unless parsed
        parsed
      end

      def self.valid?(type : String)
        !!(Resource::MAPPING.key_for?(type))
      end
    end
  end
end
