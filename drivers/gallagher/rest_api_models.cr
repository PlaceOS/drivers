require "json"

module Gallagher
  class Results(ResultType)
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property results : Array(ResultType)

    @[JSON::Field(key: "next")]
    property next_uri : NamedTuple(href: String)?
  end

  # Personal Data Field
  class PDF
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    def initialize(@id, @name, @href)
    end

    property id : String
    property name : String
    property href : String

    @[JSON::Field(key: "serverDisplayName")]
    property server_display_name : String? = nil

    property required : Bool? = nil
    property unique : Bool? = nil
    property default : String? = nil
    property description : String? = nil
  end

  class Cardholder
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    def initialize(
      @first_name,
      @last_name,
      @short_name,
      @description,
      @authorised,
      cards,
      access_groups,
      division : String?
    )
      @cards = cards
      @division = division ? {href: division} : nil
      @access_groups = access_groups
    end

    property href : String?
    property id : String?

    @[JSON::Field(key: "firstName")]
    property first_name : String?

    @[JSON::Field(key: "lastName")]
    property last_name : String?

    @[JSON::Field(key: "shortName")]
    property short_name : String?
    property description : String?
    property authorised : Bool?

    @[JSON::Field(key: "lastSuccessfulAccessTime")]
    property last_accessed : Time?

    property division : NamedTuple(href: String)?
    property usercode : String?

    property cards : Array(Card) | Hash(String, Array(Card))?

    @[JSON::Field(key: "accessGroups")]
    property access_groups : Array(CardholderAccessGroup) | Hash(String, Array(CardholderAccessGroup))?
  end

  class CardType
    include JSON::Serializable
    include JSON::Serializable::Unmapped

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
    property minimum_number : String?

    @[JSON::Field(key: "maximumNumber")]
    property maximum_number : String?
  end

  class Invitation
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property email : String?
    property mobile : String?

    @[JSON::Field(key: "singleFactorOnly")]
    property single_factor_only : Bool?

    property status : String?
    property href : String?
  end

  class Card
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    def initialize(@href, @status)
    end

    property href : String?
    property type : NamedTuple(href: String, name: String?)? = nil
    property number : String? = nil
    property status : NamedTuple(value: String, type: String?)? = nil

    @[JSON::Field(key: "cardSerialNumber")]
    property card_serial_number : String? = nil

    @[JSON::Field(key: "issueLevel")]
    property issue_level : Int32? = nil

    @[JSON::Field(key: "credentialClass")]
    property credential_class : String? = nil

    @[JSON::Field(key: "e2eKey")]
    property e2e_key : String? = nil

    @[JSON::Field(key: "bleFacilityId")]
    property ble_facility_id : Int64? = nil

    @[JSON::Field(key: "credentialId")]
    property credential_id : String? = nil

    property invitation : Invitation? = nil

    property from : Time? = nil
    property until : Time? = nil
  end

  class CardholderAccessGroup
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property href : String?

    @[JSON::Field(key: "accessGroup")]
    property access_group : NamedTuple(href: String)

    property from : Time?
    property until : Time?
  end

  class AccessGroup
    include JSON::Serializable

    property href : String
    property id : String
    property name : String
    property description : String?

    property parent : NamedTuple(
      href: String,
      name: String,
    )?

    property division : NamedTuple(
      href: String,
    )

    property cardholders : NamedTuple(
      href: String,
    )

    property children : Array(NamedTuple(
      href: String,
      name: String,
    ))?
  end

  class AccessGroupMembership
    include JSON::Serializable

    property href : String
    property cardholder : NamedTuple(
      href: String,
      name: String,
    )
    property from : Time?
    property until : Time?
  end
end
