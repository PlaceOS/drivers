require "json"

class Cisco::Ise::Models::InternalUser
  include JSON::Serializable

  @[JSON::Field(key: "name")]
  property name : String

  @[JSON::Field(key: "id")]
  property id : String?

  @[JSON::Field(key: "description")]
  property description : String?

  @[JSON::Field(key: "changePassword")]
  property change_password : Bool = false

  @[JSON::Field(key: "email")]
  property email : String?

  @[JSON::Field(key: "accountNameAlias")]
  property account_name_alias : String?

  @[JSON::Field(key: "passwordNeverExpires")]
  property password_never_expires : Bool?

  @[JSON::Field(key: "enablePassword")]
  property enable_password : Bool?

  @[JSON::Field(key: "enabled")]
  property enabled : Bool = true

  @[JSON::Field(key: "customAttributes")]
  property custom_attributes : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type

  @[JSON::Field(key: "firstName")]
  property first_name : String?

  @[JSON::Field(key: "identityGroups")]
  property identity_groups : String?

  @[JSON::Field(key: "lastName")]
  property last_name : String?

  @[JSON::Field(key: "password")]
  property password : String?

  @[JSON::Field(key: "passwordIDStore")]
  property password_store : String = "Internal Users"

  @[JSON::Field(key: "expiryDateEnabled")]
  property expiry_date_enabled : Bool?

  @[JSON::Field(key: "expiryDate")]
  property expiry_date : String?

  @[JSON::Field(key: "daysForPasswordExpiration")]
  property days_for_password_expiration : Int32? = 60
end
