require "json"
require "uuid"

class Cisco::Ise::Models::GuestInfo
  include JSON::Serializable

  @[JSON::Field(key: "emailAddress")]
  property email_address : String?

  @[JSON::Field(key: "enabled")]
  property enabled : Bool = true

  @[JSON::Field(key: "password")]
  property password : String = UUID.random.to_s.gsub("-", "")

  @[JSON::Field(key: "phoneNumber")]
  property phone_number : String?

  @[JSON::Field(key: "smsServiceProvider")]
  property sms_service_provider : String?

  @[JSON::Field(key: "userName")]
  property user_name : String?

  @[JSON::Field(key: "firstName")]
  property first_name : String?

  @[JSON::Field(key: "lastName")]
  property last_name : String?

  @[JSON::Field(key: "company")]
  property company : String?

  @[JSON::Field(key: "creationTime")]
  property creation_time : String?

  @[JSON::Field(key: "notificationLanguage")]
  property notification_language : String?
end
