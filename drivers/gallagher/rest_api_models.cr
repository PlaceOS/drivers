require "json"

module Gallagher
  class Results(ResultType)
    include JSON::Serializable

    property results : Array(ResultType)

    @[JSON::Field(key: "next")]
    property next_uri : NamedTuple(href: String)?
  end

  # Personal Data Field
  class PDF
    include JSON::Serializable

    property id : String
    property name : String
    property href : String

    @[JSON::Field(key: "serverDisplayName")]
    property server_display_name : String?
  end

  class Cardholder
    include JSON::Serializable

    property id : String

    @[JSON::Field(key: "firstName")]
    property first_name : String

    @[JSON::Field(key: "lastName")]
    property last_name : String

    @[JSON::Field(key: "shortName")]
    property short_name : String?
    property description : String?
    property href : String
    property authorised : Bool?
  end

  class CardType
    include JSON::Serializable

    property id : String
    property name : String
    property href : String

    @[JSON::Field(key: "facilityCode")]
    property facility_code : String

    @[JSON::Field(key: "availableCardStates")]
    property available_card_states : Array(String)

    @[JSON::Field(key: "credentialClass")]
    property credential_class : String

    @[JSON::Field(key: "minimumNumber")]
    property minimum_number : String

    @[JSON::Field(key: "maximumNumber")]
    property maximum_number : String
  end
end
