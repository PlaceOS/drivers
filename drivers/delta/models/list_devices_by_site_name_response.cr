require "json"

module Delta
  module Models
    struct ListDevicesBySiteNameResponse
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      @[JSON::Field(key: "$base")]
      property base : String
    end
  end
end
