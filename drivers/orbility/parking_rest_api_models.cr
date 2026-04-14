require "json"

module Orbility
  struct Auth
    include JSON::Serializable

    getter login : String
    getter password : String
    getter language : String

    def initialize(@login, @password, @language = "en")
    end
  end

  class AuthResponse
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "userToken")]
    getter user_token : String

    @[JSON::Field(key: "queryResult")]
    getter? success : Bool

    getter expires : Time { 10.hours.from_now }

    def expired?
      expires < Time.utc
    end
  end

  module Success
    def success?
      self.query_result || self.status == "OK"
    end

    getter status : String?
    getter message : String?

    @[JSON::Field(key: "queryResult")]
    getter query_result : Bool
  end

  # The response when updating things
  struct Confirmation
    include JSON::Serializable
    include Success

    getter id : Int64?

    @[JSON::Field(key: "bookingNumber")]
    getter! booking_number : String
  end

  module CreatedConverter
    FORMAT = "%Y-%m-%dT%H:%M:%S.%L"

    def self.from_json(value : JSON::PullParser) : Time
      str = value.read_string

      begin
        # the milliseconds may not exist or are not padded
        result = str.split('.', 2)
        timemain = result[0]
        if result.size == 1
          split = "000"
        else
          split = result[1].ljust(3, '0')
        end
        str = "#{timemain}.#{split}"
        Time.parse(str, FORMAT, Time::Location::UTC)
      rescue error
        # puts "ERROR PARSING: #{str}"
        raise error
      end
    end

    def self.to_json(value : Time, json : JSON::Builder) : Nil
      json.string(value.to_s(FORMAT))
    end
  end

  module TimeConverter
    FORMAT = "%Y-%m-%dT%H:%M:%S"

    def self.from_json(value : JSON::PullParser) : Time
      Time.parse(value.read_string, FORMAT, Time::Location::UTC)
    end

    def self.to_json(value : Time, json : JSON::Builder) : Nil
      json.string(value.to_s(FORMAT))
    end
  end

  struct Product
    include JSON::Serializable
    include JSON::Serializable::Unmapped
    include Success

    @[JSON::Field(key: "producId")]
    getter id : Int64

    @[JSON::Field(key: "producName")]
    getter name : String

    @[JSON::Field(key: "producDescription")]
    getter description : String?

    @[JSON::Field(key: "producNumber")]
    getter number : Int32
  end

  struct Products
    include JSON::Serializable
    include Success

    getter products : Array(Product)
  end

  struct Offer
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "offerId")]
    getter id : Int64

    @[JSON::Field(key: "offerName")]
    getter name : String

    @[JSON::Field(key: "beginValidityDate", converter: Orbility::TimeConverter)]
    getter begin_valid : Time?

    @[JSON::Field(key: "endValidityDate", converter: Orbility::TimeConverter)]
    getter end_valid : Time?

    def valid?(at = Time.utc)
      start = begin_valid
      ending = end_valid
      return true unless start || ending
      return false if begin_valid && at < begin_valid
      return false if end_valid && at >= end_valid
      true
    end
  end

  struct Offers
    include JSON::Serializable
    include Success

    getter offers : Array(Offer)
  end

  struct Person
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "isCompany")]
    getter? company : Bool
    getter name : String # this is last name or company name

    @[JSON::Field(key: "firstName")]
    getter first_name : String?
    getter title : String?

    # we'll store user ids here
    getter comment : String?

    getter emails : Array(String)

    def initialize(@first_name, @name, @comment, @emails)
      @company = false
      @title = nil
    end
  end

  struct Contract
    include JSON::Serializable
    include JSON::Serializable::Unmapped
    include Success

    @[JSON::Field(key: "contractNumber")]
    getter id : Int64
    getter name : String

    @[JSON::Field(key: "artificialPerson")]
    getter company : Person
  end

  # example add {"ProductId":6,"contractNumber":6,"offerId":3,"validityStartDate":"2025-04-17T00:00:00","validityEndDate":"2050-01-01T00:00:00"}
  struct Subscription
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter! id : Int64

    # patching and viewing data have different names for the same field
    @[JSON::Field(key: "producId")]
    property receive_product_id : Int64?

    @[JSON::Field(key: "productId")]
    property send_product_id : Int64?

    def product_id : Int64
      receive_product_id || send_product_id.as(Int64)
    end

    @[JSON::Field(key: "contractNumber")]
    getter contract_id : Int64

    # doesn't look like offers are required for a subscription!
    @[JSON::Field(key: "offerId")]
    getter offer_id : Int64?

    @[JSON::Field(key: "creationDate", converter: Orbility::CreatedConverter)]
    getter created : Time?

    @[JSON::Field(key: "validityStartDate", converter: Orbility::TimeConverter)]
    getter start_date : Time

    @[JSON::Field(key: "validityEndDate", converter: Orbility::TimeConverter)]
    property end_date : Time

    @[JSON::Field(key: "cards")]
    getter! card_ids : Array(Int64)

    def valid?(at = Time.utc)
      (start_date...end_date).includes?(at)
    end

    def initialize(product_id : Int64, @contract_id, @offer_id, @start_date, @end_date, @id = nil)
      @send_product_id = product_id
    end
  end

  struct MultiSubscriptions
    include JSON::Serializable
    include Success

    getter subscriptions : Array(Subscription)
  end

  struct SingleSubscription
    include JSON::Serializable
    include Success

    getter subscription : Subscription
  end

  enum FirstUseType
    Entry
    Exit
    EntryOrExit

    def to_json(json : JSON::Builder)
      json.string(self.to_s)
    end
  end

  struct Card
    include JSON::Serializable
    include JSON::Serializable::Unmapped
    include Success

    @[JSON::Field(key: "cardNumber")]
    getter id : Int64

    @[JSON::Field(key: "subscriptionId")]
    getter subscription_id : Int64

    @[JSON::Field(key: "externalNumber")]
    getter access_card_no : String?

    @[JSON::Field(key: "licencePlates")]
    getter licence_plates : Array(String) { [] of String }

    @[JSON::Field(key: "isLicensePlateRegistered")]
    getter? license_plate_registered : Bool

    @[JSON::Field(key: "artificialPerson")]
    getter person : Person

    @[JSON::Field(key: "firstUseType")]
    getter first_use_type : FirstUseType = FirstUseType::EntryOrExit

    @[JSON::Field(key: "firUseTypId")]
    getter first_use_type_id : FirstUseType = FirstUseType::EntryOrExit
  end

  # example add {"cardNumber": 4,"subscriptionId":4,"licencePlates":["test1"],"artificialPerson":{"isCompany": false, "name":"von Takach","firstName": "Steve", "companyNumber": "12345", "emails": ["steve@vontaka.ch"]}}
  struct CardUpdate
    include JSON::Serializable

    @[JSON::Field(key: "cardNumber")]
    getter id : Int64

    @[JSON::Field(key: "subscriptionId")]
    getter subscription_id : Int64

    @[JSON::Field(key: "externalNumber")]
    getter access_card_no : String?

    @[JSON::Field(key: "licencePlates")]
    getter licence_plates : Array(String) = [] of String

    @[JSON::Field(key: "isLicensePlateRegistered")]
    getter? license_plate_registered : Bool

    @[JSON::Field(key: "artificialPerson")]
    getter person : Person

    @[JSON::Field(key: "firstUseType")]
    getter first_use_type : FirstUseType = FirstUseType::EntryOrExit

    @[JSON::Field(key: "firUseTypId")]
    getter first_use_type_id : FirstUseType = FirstUseType::EntryOrExit

    def initialize(@subscription_id, @access_card_no, @licence_plates, @person, id : Int64? = nil)
      @id = id || @subscription_id
      @license_plate_registered = !@licence_plates.empty?
      @first_use_type = FirstUseType::EntryOrExit
      @first_use_type_id = FirstUseType::EntryOrExit
    end
  end

  ##############################
  # PreBookings
  ##############################

  struct UserInfo
    include JSON::Serializable

    getter name : String

    @[JSON::Field(key: "licensePlate")]
    getter license_plate : String?

    def initialize(@name, @license_plate = nil)
    end
  end

  struct Access
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    enum Mode
      OnePass
      MultiPass

      def to_json(json : JSON::Builder)
        json.string(self.to_s)
      end
    end

    @[JSON::Field(key: "accessMode")]
    getter access_mode : Mode

    @[JSON::Field(key: "productId")]
    getter product_id : Int64?

    def initialize(@access_mode, @product_id = nil)
    end
  end

  struct PreBooking
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "bookingNumber")]
    getter! id : String

    @[JSON::Field(key: "startDate")]
    getter start_date : Time

    @[JSON::Field(key: "endDate")]
    getter end_date : Time

    getter category : Int32

    @[JSON::Field(key: "userInfo")]
    getter user_info : UserInfo

    getter access : Access

    def initialize(@start_date, @end_date, @user_info, @access, @category = 0, @id = nil)
    end
  end

  struct BookingInfo
    include JSON::Serializable
    include JSON::Serializable::Unmapped
    include Success

    def id : String
      booking_number
    end

    @[JSON::Field(key: "licensePlate")]
    getter license_plate : String?

    @[JSON::Field(key: "actualEntry")]
    getter actual_entry : String?

    @[JSON::Field(key: "actualExit")]
    getter actual_exit : String?
  end
end
