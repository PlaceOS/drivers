require "json"

class Cisco::Ise::Models::GuestAccessInfo
  include JSON::Serializable

  @[JSON::Field(key: "validDays")]
  property valid_days : Int32?

  @[JSON::Field(key: "fromDate")]
  property from_date : String?

  @[JSON::Field(key: "toDate")]
  property to_date : String?

  @[JSON::Field(key: "location")]
  property location : String?

  @[JSON::Field(key: "ssid")]
  property ssid : String?

  @[JSON::Field(key: "groupTag")]
  property group_tag : String?
end
