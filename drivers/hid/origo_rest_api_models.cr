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

    @[JSON::Field(key: "passTemplateId")]
    property pass_template_id : String?

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

    @[JSON::Field(key: "issuanceToken")]
    property issuance_token : IssuanceTokenRequest?

    property credentials : Array(CredentialRequest)?

    def initialize(@user_id : String, @pass_template_id : String)
    end

    def initialize(@user_id : String?, @status : String? = "active")
    end

    def initialize(@status : String)
    end

    def initialize
    end
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

  # Pass Template Models
  struct PassTemplate
    include JSON::Serializable

    property id : String?
    property name : String?
    property description : String?

    @[JSON::Field(key: "organizationName")]
    property organization_name : String?

    @[JSON::Field(key: "privacyPolicyUrl")]
    property privacy_policy_url : String?

    @[JSON::Field(key: "termsOfServiceUrl")]
    property terms_of_service_url : String?

    @[JSON::Field(key: "websiteUrl")]
    property website_url : String?

    @[JSON::Field(key: "supportPhoneNumber")]
    property support_phone_number : String?

    @[JSON::Field(key: "emailAddress")]
    property email_address : String?

    @[JSON::Field(key: "supportDisplayName")]
    property support_display_name : String?

    @[JSON::Field(key: "lostAndFoundUrl")]
    property lost_and_found_url : String?

    @[JSON::Field(key: "registrationUrl")]
    property registration_url : String?

    @[JSON::Field(key: "credentialTemplateIdentifiers")]
    property credential_template_identifiers : Array(String)?

    @[JSON::Field(key: "passDesignIdentifier")]
    property pass_design_identifier : String?

    property default : Bool?

    @[JSON::Field(key: "appleWalletConfiguration")]
    property apple_wallet_configuration : AppleWalletConfiguration?

    @[JSON::Field(key: "googleWalletConfiguration")]
    property google_wallet_configuration : GoogleWalletConfiguration?

    def initialize(@description : String, @credential_template_identifiers : Array(String))
    end

    def initialize(@credential_template_identifiers : Array(String))
    end

    def initialize
    end
  end

  struct AppleWalletConfiguration
    include JSON::Serializable

    property tcis : Array(String)?

    @[JSON::Field(key: "cardTemplateIdentifier")]
    property card_template_identifier : String?
  end

  struct GoogleWalletConfiguration
    include JSON::Serializable

    @[JSON::Field(key: "issuerId")]
    property issuer_id : String?

    @[JSON::Field(key: "issuerApp")]
    property issuer_app : IssuerApp?

    @[JSON::Field(key: "serviceProviderId")]
    property service_provider_id : String?
  end

  struct IssuerApp
    include JSON::Serializable

    @[JSON::Field(key: "packageName")]
    property package_name : String?

    property action : String?
  end

  struct PassTemplateCollection
    include JSON::Serializable

    @[JSON::Field(key: "passTemplates")]
    property pass_templates : Array(PassTemplate)

    @[JSON::Field(key: "totalItems")]
    property total_items : Int32?

    property page : Int32?

    @[JSON::Field(key: "perPage")]
    property per_page : Int32?

    property links : Array(Link)?
  end

  struct Link
    include JSON::Serializable

    property rel : String?
    property href : String?
  end

  struct IssuanceTokenRequest
    include JSON::Serializable

    @[JSON::Field(key: "applicationIds")]
    property application_ids : Array(String)?

    property credentials : Array(CredentialRequest)?
  end

  struct CredentialRequest
    include JSON::Serializable

    @[JSON::Field(key: "credentialTemplateId")]
    property credential_template_id : String?

    @[JSON::Field(key: "credentialId")]
    property credential_id : String?

    @[JSON::Field(key: "cardData")]
    property card_data : String?

    @[JSON::Field(key: "deviceTrackingId")]
    property device_tracking_id : String?
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
