require "./events"

class Cisco::DNASpaces::LocationDetails
  include JSON::Serializable

  @[JSON::Field(key: "timeZone")]
  getter time_zone : String

  getter city : String
  getter state : String
  getter country : String
  getter category : String

  getter latitude : Float64
  getter longitude : Float64
end
