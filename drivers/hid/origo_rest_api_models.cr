require "json"

module HID
  # Authentication Models
  struct TokenResponse
    include JSON::Serializable

    property access_token : String
    property expires_in : Int32
    property token_type : String
  end

  # SCIM User Management Models
  struct Name
    include JSON::Serializable

    @[JSON::Field(key: "givenName")]
    property given_name : String?

    @[JSON::Field(key: "familyName")]
    property family_name : String?

    @[JSON::Field(key: "middleName")]
    property middle_name : String?

    @[JSON::Field(key: "honorificPrefix")]
    property honorific_prefix : String?

    @[JSON::Field(key: "honorificSuffix")]
    property honorific_suffix : String?
  end

  struct Email
    include JSON::Serializable

    property value : String
    property type : String?
    property primary : Bool?
  end

  struct PhoneNumber
    include JSON::Serializable

    property value : String
    property type : String?
  end

  struct Meta
    include JSON::Serializable

    @[JSON::Field(key: "lastModified")]
    property last_modified : String?

    property location : String?

    @[JSON::Field(key: "resourceType")]
    property resource_type : String?
  end

  struct User
    include JSON::Serializable

    property id : Int64?

    @[JSON::Field(key: "externalId")]
    property external_id : String?

    property name : Name?
    property emails : Array(Email)?

    @[JSON::Field(key: "phoneNumbers")]
    property phone_numbers : Array(PhoneNumber)?

    property active : Bool?
    property schemas : Array(String)?
    property meta : Meta?

    # Enterprise user extension - handled separately due to complex field name
    # property enterprise_user : EnterpriseUser?

    def initialize(@user_name : String?, @display_name : String?, @active : Bool? = true)
      @schemas = ["urn:ietf:params:scim:schemas:core:2.0:User"]
    end
  end

  struct PaginatedUserList
    include JSON::Serializable

    @[JSON::Field(key: "totalResults")]
    property total_results : Int32

    @[JSON::Field(key: "itemsPerPage")]
    property items_per_page : Int32

    @[JSON::Field(key: "startIndex")]
    property start_index : Int32

    property schemas : Array(String)

    @[JSON::Field(key: "Resources")]
    property resources : Array(User)
  end

  struct UserSearchRequest
    include JSON::Serializable

    property schemas : Array(String)
    property attributes : Array(String)?
    property filter : String

    @[JSON::Field(key: "startIndex")]
    property start_index : Int32

    @[JSON::Field(key: "sortOrder")]
    property sort_order : String = "descending"
    property count : Int32

    def initialize(@filter : String, @start_index : Int32 = 0, @count : Int32 = 20)
      @schemas = ["urn:ietf:params:scim:api:messages:2.0:SearchRequest"]
      @attributes = [
        "urn:ietf:params:scim:schemas:core:2.0:User:emails",
        "name.familyName",
        "name.givenName",
      ]
    end
  end

  # Error Response Models
  struct ErrorResponse
    include JSON::Serializable

    property status : String

    @[JSON::Field(key: "scimType")]
    property scim_type : String?

    property message : String
    property schemas : Array(String)
  end
end
