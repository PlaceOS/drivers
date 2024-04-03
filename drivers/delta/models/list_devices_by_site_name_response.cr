require "json"

module Delta
  module Models
    struct ListDevicesBySiteNameResponse
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      @[JSON::Field(key: "$base")]
      property base : String? = nil

      # returns this when there are no more results
      @[JSON::Field(key: "Collection")]
      property collection : String? = nil

      @[JSON::Field(key: "next")]
      property next_req : String? = nil
    end
  end
end
