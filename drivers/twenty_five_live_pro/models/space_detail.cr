require "json"

require "./expanded/**"

module TwentyFiveLivePro
  module Models
    struct SpaceDetail
      include JSON::Serializable

      struct Content
        include JSON::Serializable

        @[JSON::Field(key: "requestId")]
        property request_id : Int64

        @[JSON::Field(key: "updated")]
        property updated : String

        struct Data
          include JSON::Serializable

          struct Space
            include JSON::Serializable

            @[JSON::Field(key: "kind")]
            property kind : String

            @[JSON::Field(key: "id")]
            property id : Int64

            @[JSON::Field(key: "etag")]
            property etag : String

            @[JSON::Field(key: "spaceName")]
            property space_name : String

            @[JSON::Field(key: "spaceFormalName")]
            property space_formal_name : String?

            @[JSON::Field(key: "maxCapacity")]
            property max_capacity : Int64

            @[JSON::Field(key: "updated")]
            property updated : String

            @[JSON::Field(key: "layouts")]
            property layouts : Array(Layout)?

            @[JSON::Field(key: "features")]
            property features : Array(Feature)?

            @[JSON::Field(key: "categories")]
            property categories : Array(Category)?

            @[JSON::Field(key: "attributes")]
            property attributes : Array(Attribute)?

            @[JSON::Field(key: "roles")]
            property roles : Array(Role)?
          end

          @[JSON::Field(key: "items")]
          property items : Array(Space)
        end

        @[JSON::Field(key: "data")]
        property data : Data

        struct ExpandedInfo
          include JSON::Serializable

          @[JSON::Field(key: "layouts")]
          property layouts : Array(Expanded::Layout)?

          @[JSON::Field(key: "features")]
          property features : Array(Expanded::Feature)?

          @[JSON::Field(key: "categories")]
          property categories : Array(Expanded::Category)?

          @[JSON::Field(key: "attributes")]
          property attributes : Array(Expanded::Attribute)?

          @[JSON::Field(key: "roles")]
          property roles : Array(Expanded::Role)?

          @[JSON::Field(key: "contacts")]
          property contacts : Array(Expanded::Contact)?
        end

        @[JSON::Field(key: "expandedInfo")]
        property expanded_info : ExpandedInfo?
      end

      @[JSON::Field(key: "content")]
      property content : Content
    end
  end
end
