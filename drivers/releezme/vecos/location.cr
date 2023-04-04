require "json"

module Releezme
  struct Location
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "TimeZoneId")]
    getter time_zone : String? = nil
  end
end
