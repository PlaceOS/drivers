require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct ParentNode
        include JSON::Serializable

        @[JSON::Field(key: "id")]
        property id : Int64
        @[JSON::Field(key: "locator")]
        property locator : String
        @[JSON::Field(key: "name")]
        property name : String
        @[JSON::Field(key: "title")]
        property title : String
        @[JSON::Field(key: "nodeType")]
        property node_type : String
        @[JSON::Field(key: "typeName")]
        property type_name : String
        @[JSON::Field(key: "startDt")]
        property start_dt : String
        @[JSON::Field(key: "endDt")]
        property end_dt : String
      end
    end
  end
end
