require "json"

module HID
  # Authentication Models
  struct TokenRequest
    include JSON::Serializable

    property client_id : String
    property client_secret : String
    property grant_type : String = "client_credentials"

    def initialize(@client_id : String, @client_secret : String)
    end
  end

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

  struct Role
    include JSON::Serializable

    property value : String
    property type : String?
    property display : String?
    property primary : Bool?
  end

  struct Group
    include JSON::Serializable

    property value : String
    property type : String?
    property display : String?
    @[JSON::Field(key: "$ref")]
    property ref : String?
  end

  struct EnterpriseUser
    include JSON::Serializable

    @[JSON::Field(key: "employeeNumber")]
    property employee_number : String?

    property department : String?
    property organization : String?
  end

  struct Meta
    include JSON::Serializable

    property created : String?

    @[JSON::Field(key: "lastModified")]
    property last_modified : String?

    property location : String?

    @[JSON::Field(key: "resourceType")]
    property resource_type : String?

    property version : String?
  end

  struct User
    include JSON::Serializable

    property id : String?

    @[JSON::Field(key: "userName")]
    property user_name : String?

    @[JSON::Field(key: "displayName")]
    property display_name : String?

    @[JSON::Field(key: "externalId")]
    property external_id : String?

    property name : Name?
    property emails : Array(Email)?

    @[JSON::Field(key: "phoneNumbers")]
    property phone_numbers : Array(PhoneNumber)?

    property active : Bool?

    @[JSON::Field(key: "userType")]
    property user_type : String?

    property roles : Array(Role)?
    property groups : Array(Group)?
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
    property filter : String

    @[JSON::Field(key: "startIndex")]
    property start_index : Int32

    property count : Int32

    def initialize(@filter : String, @start_index : Int32 = 0, @count : Int32 = 20)
      @schemas = ["urn:ietf:params:scim:api:messages:2.0:SearchRequest"]
    end
  end

  enum PassStatus
    Created
    IssueInitiated
    Issuing
    IssueFailed
    Cancelled
    Active
    Suspending
    Suspended
    Resuming
    Revoking
    Revoked
    RevokeFailed
    UserResuming
    UserSuspended
    UserSuspending
    UserRevoking
  end

  # Credential Management Models
  struct Pass
    include JSON::Serializable

    property id : String?

    @[JSON::Field(key: "userId")]
    property user_id : String?

    property status : String?

    @[JSON::Field(key: "createdAt")]
    property created_at : String?

    @[JSON::Field(key: "updatedAt")]
    property updated_at : String?

    @[JSON::Field(key: "expiresAt")]
    property expires_at : String?

    @[JSON::Field(key: "cardNumber")]
    property card_number : String?

    @[JSON::Field(key: "facilityCode")]
    property facility_code : String?

    def initialize(@user_id : String?, @status : String? = "active")
    end
  end

  struct PassDetails
    include JSON::Serializable

    property id : String?

    @[JSON::Field(key: "userId")]
    property user_id : String?

    property status : String?

    @[JSON::Field(key: "createdAt")]
    property created_at : String?

    @[JSON::Field(key: "updatedAt")]
    property updated_at : String?

    @[JSON::Field(key: "expiresAt")]
    property expires_at : String?

    @[JSON::Field(key: "cardNumber")]
    property card_number : String?

    @[JSON::Field(key: "facilityCode")]
    property facility_code : String?

    property permissions : Array(String)?
  end

  struct PassCollection
    include JSON::Serializable

    property passes : Array(Pass)

    @[JSON::Field(key: "totalCount")]
    property total_count : Int32?

    property page : Int32?

    @[JSON::Field(key: "perPage")]
    property per_page : Int32?
  end

  struct CreatePassRequest
    include JSON::Serializable

    @[JSON::Field(key: "userId")]
    property user_id : String

    property status : String?

    @[JSON::Field(key: "expiresAt")]
    property expires_at : String?

    @[JSON::Field(key: "cardNumber")]
    property card_number : String?

    @[JSON::Field(key: "facilityCode")]
    property facility_code : String?

    property permissions : Array(String)?

    def initialize(@user_id : String, @status : String? = "active")
    end
  end

  struct UpdatePassRequest
    include JSON::Serializable

    property status : String?

    @[JSON::Field(key: "expiresAt")]
    property expires_at : String?

    property permissions : Array(String)?

    def initialize(@status : String? = nil)
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
