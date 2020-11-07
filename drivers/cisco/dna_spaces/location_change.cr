require "./events"

class Cisco::DNASpaces::LocationChange
  include JSON::Serializable

  @[JSON::Field(key: "changeType")]
  getter change_type : String
  getter location : Location

  class Metadata
    include JSON::Serializable

    getter key : String
    getter values : Array(String)
  end

  class LocationDetails
    include JSON::Serializable

    @[JSON::Field(key: "timeZone")]
    getter time_zone : String
    getter city : String
    getter state : String
    getter country : String
    getter category : String

    getter latitude : Float64
    getter longitude : Float64

    getter metadata : Array(Metadata)
  end
end
