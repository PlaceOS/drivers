require "json"

module Delta
  module Models
    struct ListSitesResponse
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "nodeType")]
      property node_type : String
    end
  end
end
