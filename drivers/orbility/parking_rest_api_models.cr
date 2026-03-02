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

    getter status : String
    getter message : String?

    @[JSON::Field(key: "queryResult")]
    getter query_result : Bool
  end

  # The response when updating things
  struct Confirmation
    include JSON::Serializable
    include Success
  end

  module CreatedConverter
    FORMAT = "%Y-%m-%dT%H:%M:%S.%L"

    def self.from_json(value : JSON::PullParser) : Time
      Time.parse(value.read_string, FORMAT, Time::Location::UTC)
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

    @[JSON::Field(key: "companyNumber")]
    getter unique_id : String?

    getter emails : Array(String)
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

  struct Subscription
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : Int64?

    @[JSON::Field(key: "producId")]
    getter product_id : Int64

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
    getter end_date : Time

    @[JSON::Field(key: "cards")]
    getter! card_ids : Array(Int64)

    def valid?(at = Time.utc)
      (start_date...end_date).includes?(at)
    end

    def initialize(@product_id, @contract_id, @offer_id, @start_date, @end_date, @id = nil)
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

  struct Card
    include JSON::Serializable
    include JSON::Serializable::Unmapped
    include Success

    @[JSON::Field(key: "cardNumber")]
    getter id : Int64

    @[JSON::Field(key: "subscriptionId")]
    getter subscription_id : Int64

    @[JSON::Field(key: "externalNumber")]
    property access_card_no : String?

    @[JSON::Field(key: "licencePlates")]
    property licence_plates : Array(String)

    @[JSON::Field(key: "artificialPerson")]
    property person : Person
  end

  struct CardUpdate
    include JSON::Serializable

    @[JSON::Field(key: "cardNumber")]
    getter id : Int64?

    @[JSON::Field(key: "subscriptionId")]
    getter subscription_id : Int64

    @[JSON::Field(key: "externalNumber")]
    property access_card_no : String?

    @[JSON::Field(key: "licencePlates")]
    property licence_plates : Array(String) = [] of String

    @[JSON::Field(key: "artificialPerson")]
    property person : Person

    def initialize(@subscription_id, @access_card_no, @licence_plates, @person, @id = nil)
    end
  end
end
