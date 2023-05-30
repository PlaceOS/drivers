require "json"
require "./expanded/conflict"

module TwentyFiveLivePro
  module Models
    struct Availability
      include JSON::Serializable

      struct Content
        include JSON::Serializable

        @[JSON::Field(key: "requestId")]
        property request_id : String

        @[JSON::Field(key: "updated")]
        property updated : String

        struct Data
          include JSON::Serializable

          struct Space
            include JSON::Serializable

            @[JSON::Field(key: "spaceId")]
            property space_id : Int64

            @[JSON::Field(key: "dates")]
            property dates : Array(Hash(String, JSON::Any))

            @[JSON::Field(key: "available")]
            property available : Bool

            @[JSON::Field(key: "conflictType")]
            property conflict_type : Int64?
          end

          @[JSON::Field(key: "spaces")]
          property spaces : Array(Space)
        end

        @[JSON::Field(key: "data")]
        property data : Data

        struct ExpandedInfo
          include JSON::Serializable

          @[JSON::Field(key: "conflictTypes")]
          property conflict_types : Array(Expanded::Conflict)?
        end

        @[JSON::Field(key: "expandedInfo")]
        property expanded_info : ExpandedInfo?
      end

      @[JSON::Field(key: "content")]
      property content : Content
    end
  end
end
