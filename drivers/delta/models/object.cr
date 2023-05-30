require "json"

module Delta
  module Models
    struct Object
      include JSON::Serializable

      @[JSON::Field(key: "id")]
      property id : String

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "displayName")]
      property display_name : String

      @[JSON::Field(key: "truncated")]
      property truncated : Bool

      def initialize(@id : String, @base : String, @display_name : String, @truncated : Bool)
      end
    end
  end
end
