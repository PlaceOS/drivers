require "json"

module Delta
  module Models
    struct Object
      include JSON::Serializable

      property object_type : String
      property instance : UInt32

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "displayName")]
      property display_name : String

      def initialize(@object_type : String, instance : String, @base : String, @display_name : String)
        @instance = instance.to_u32
      end
    end
  end
end
