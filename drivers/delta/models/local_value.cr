require "json"

module Delta
  module Models
    struct LocalValue
      include JSON::Serializable

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "real")]
      property real : GenericValue
    end
  end
end
