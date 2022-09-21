require "./events"

class Cisco::DNASpaces::Device
  include JSON::Serializable

  @[JSON::Field(key: "deviceId")]
  getter device_id : String

  @[JSON::Field(key: "userId")]
  getter user_id : String

  getter tags : Array(String) = [] of String
  getter mobile : String?
  getter email : String?

  def email
    @email.try &.downcase
  end

  def email_raw
    @email
  end

  getter gender : String?

  @[JSON::Field(key: "firstName")]
  getter first_name : String?

  @[JSON::Field(key: "lastName")]
  getter last_name : String?

  @[JSON::Field(key: "postalCode")]
  getter postal_code : String?

  # optIns
  # otherFields
  # socialNetworkInfo

  # We make this editable so we can store the formatted version here
  @[JSON::Field(key: "macAddress")]
  property mac_address : String
  getter manufacturer : String?
  getter os : String?

  @[JSON::Field(key: "osVersion")]
  getter os_version : String?
  getter type : String
end
