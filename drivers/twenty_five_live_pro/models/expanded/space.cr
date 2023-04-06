require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct Space
        include JSON::Serializable

        @[JSON::Field(key: "spaceId")]
        property space_id : Int64
        @[JSON::Field(key: "etag")]
        property etag : String
        @[JSON::Field(key: "spaceName")]
        property space_name : String
        @[JSON::Field(key: "spaceFormalName")]
        property space_formal_name : String
        @[JSON::Field(key: "maxCapacity")]
        property max_capacity : Int64
      end
    end
  end
end
