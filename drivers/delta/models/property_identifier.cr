require "json"

module Delta
  module Models
    struct PropertyIdentifier
      include JSON::Serializable

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "value")]
      property value : JSON::Any

      @[JSON::Field(key: "type")]
      property type : String
    end
  end
end
