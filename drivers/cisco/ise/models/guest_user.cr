require "json"
require "./guest_info"
require "./guest_access_info"

class Cisco::Ise::Models::GuestUser
  include JSON::Serializable

  @[JSON::Field(key: "name")]
  property name : String = "gusetUser"

  @[JSON::Field(key: "id")]
  property id : String?

  @[JSON::Field(key: "description")]
  property description : String?

  @[JSON::Field(key: "customFields")]
  property custom_fields : Hash(String, String) = {} of String => String

  @[JSON::Field(key: "guestType")]
  property guest_type : String?

  @[JSON::Field(key: "status")]
  property status : String?

  @[JSON::Field(key: "reasonForVisit")]
  property reason_for_visit : String?

  @[JSON::Field(key: "personBeingVisited")]
  property person_being_visited : String?

  @[JSON::Field(key: "sponsorUserName")]
  property sponsor_user_name : String?

  @[JSON::Field(key: "sponsorUserId")]
  property sponsor_user_id : String?

  @[JSON::Field(key: "statusReason")]
  property status_reason : String?

  @[JSON::Field(key: "portalId")]
  property portal_id : String?

  @[JSON::Field(key: "guestAccessInfo")]
  property guest_access_info : GuestAccessInfo = GuestAccessInfo.from_json(%({}))

  @[JSON::Field(key: "guestInfo")]
  property guest_info : GuestInfo = GuestInfo.from_json(%({}))
end
