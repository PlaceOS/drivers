require "json"

module HID
  # Authentication Models
  struct TokenResponse
    include JSON::Serializable

    getter access_token : String
    getter expires_in : Int32
    getter token_type : String
  end

  # SCIM User Management Models
  struct Name
    include JSON::Serializable

    @[JSON::Field(key: "givenName")]
    getter given_name : String?

    @[JSON::Field(key: "familyName")]
    getter family_name : String?

    @[JSON::Field(key: "middleName")]
    getter middle_name : String?

    @[JSON::Field(key: "honorificPrefix")]
    getter honorific_prefix : String?

    @[JSON::Field(key: "honorificSuffix")]
    getter honorific_suffix : String?
  end

  struct Email
    include JSON::Serializable

    getter value : String
    getter type : String?
    getter primary : Bool?
  end

  struct PhoneNumber
    include JSON::Serializable

    getter value : String
    getter type : String?
  end

  struct Meta
    include JSON::Serializable

    @[JSON::Field(key: "lastModified")]
    getter last_modified : String?

    getter location : String

    @[JSON::Field(key: "resourceType")]
    getter resource_type : String?
  end

  struct User
    include JSON::Serializable

    getter id : Int64?

    @[JSON::Field(key: "externalId")]
    getter external_id : String?

    getter name : Name?
    getter emails : Array(Email)?

    @[JSON::Field(key: "phoneNumbers")]
    getter phone_numbers : Array(PhoneNumber)?

    getter active : Bool?
    getter schemas : Array(String)?
    getter meta : Meta

    def extract_id : Int64 | String
      id || meta.location.split("/").last
    end

    # Enterprise user extension - handled separately due to complex field name
    # getter enterprise_user : EnterpriseUser?

    def initialize(@user_name : String?, @display_name : String?, @active : Bool? = true)
      @schemas = ["urn:ietf:params:scim:schemas:core:2.0:User"]
      @meta = nil
    end
  end

  struct Paginated(Type)
    include JSON::Serializable

    @[JSON::Field(key: "totalResults")]
    getter total_results : Int32

    @[JSON::Field(key: "itemsPerPage")]
    getter items_per_page : Int32

    @[JSON::Field(key: "startIndex")]
    getter start_index : Int32

    getter schemas : Array(String)

    @[JSON::Field(key: "Resources")]
    getter resources : Array(Type)
  end

  struct ListResponse
    include JSON::Serializable

    getter meta : Meta
  end

  struct UserSearchRequest
    include JSON::Serializable

    getter schemas : Array(String)
    getter attributes : Array(String)?
    getter filter : String

    @[JSON::Field(key: "startIndex")]
    getter start_index : Int32

    @[JSON::Field(key: "sortOrder")]
    getter sort_order : String = "descending"
    getter count : Int32

    def initialize(@filter : String, @start_index : Int32 = 0, @count : Int32 = 20)
      @schemas = ["urn:ietf:params:scim:api:messages:2.0:SearchRequest"]
      @attributes = [
        "urn:ietf:params:scim:schemas:core:2.0:User:emails",
        "name.familyName",
        "name.givenName",
      ]
    end
  end

  struct PartNumber
    include JSON::Serializable

    getter id : String

    @[JSON::Field(key: "partNumber")]
    getter number : String

    @[JSON::Field(key: "friendlyName")]
    getter name : String?

    @[JSON::Field(key: "availableQty")]
    getter available : Int32?

    getter meta : Meta

    getter badge_type : String?
  end

  struct SchemaResponse
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter schemas : Array(String)
  end

  struct UserInvitation
    include JSON::Serializable

    getter meta : Meta
    getter id : Int64

    @[JSON::Field(key: "invitationCode")]
    getter code : String
    getter status : String
  end

  struct Credential
    include JSON::Serializable

    getter id : Int64

    @[JSON::Field(key: "partNumber")]
    getter part_number : String

    @[JSON::Field(key: "partNumberFriendlyName")]
    getter part_name : String?

    @[JSON::Field(key: "cardNumber")]
    getter card_number : String?

    @[JSON::Field(key: "credentialType")]
    getter type : String?

    getter status : String
  end

  # Error Response Models
  struct ErrorResponse
    include JSON::Serializable

    getter status : String

    @[JSON::Field(key: "scimType")]
    getter scim_type : String?

    getter message : String
    getter schemas : Array(String)
  end
end
