require "json"

module Delta
  module Models
    struct GenericValue
      include JSON::Serializable

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "value")]
      property value : JSON::Any
    end
  end
end
