require "json"

module Delta
  module Models
    struct Device
      include JSON::Serializable

      @[JSON::Field(key: "id")]
      property id : UInt32

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "nodeType")]
      property node_type : String

      @[JSON::Field(key: "displayName")]
      property display_name : String

      def initialize(@id : UInt32, @base : String, @node_type : String, @display_name : String)
      end
    end
  end
end
