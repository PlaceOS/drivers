require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct Attribute
        include JSON::Serializable

        @[JSON::Field(key: "attributeId")]
        property attribute_id : Int64
        @[JSON::Field(key: "attributeName")]
        property attribute_name : String
        @[JSON::Field(key: "attributeType")]
        property attribute_type : String?
      end
    end
  end
end
