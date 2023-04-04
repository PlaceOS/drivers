require "json"

module Releezme
  struct Section
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "LocationId")]
    getter location_id : String
  end
end
