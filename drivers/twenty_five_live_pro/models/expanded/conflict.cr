require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct Conflict
        include JSON::Serializable

        @[JSON::Field(key: "conflictTypeId")]
        property conflict_type_id : Int64
        @[JSON::Field(key: "conflictTypeName")]
        property conflict_type_name : String
        @[JSON::Field(key: "conflictTypeDescription")]
        property conflict_type_description : String
      end
    end
  end
end
