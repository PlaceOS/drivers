require "json"

require "./expanded/category.cr"
require "./expanded/attribute.cr"

module TwentyFiveLivePro
  module Models
    struct ResourceDetail
      include JSON::Serializable

      struct Content
        include JSON::Serializable

        @[JSON::Field(key: "requestId")]
        property request_id : Int64

        @[JSON::Field(key: "updated")]
        property updated : String

        struct Data
          include JSON::Serializable

          struct Resource
            include JSON::Serializable

            @[JSON::Field(key: "kind")]
            property kind : String

            @[JSON::Field(key: "id")]
            property id : Int64

            @[JSON::Field(key: "etag")]
            property etag : String

            @[JSON::Field(key: "resourceName")]
            property resource_name : String

            @[JSON::Field(key: "updated")]
            property updated : String
          end

          @[JSON::Field(key: "items")]
          property items : Array(Resource)
        end

        @[JSON::Field(key: "data")]
        property data : Data

        struct ExpandedInfo
          include JSON::Serializable

          @[JSON::Field(key: "categories")]
          property categories : Array(Expanded::Category)?

          @[JSON::Field(key: "attributes")]
          property attributes : Array(Expanded::Attribute)?
        end

        @[JSON::Field(key: "expandedInfo")]
        property expanded_info : Array(ExpandedInfo)?
      end

      @[JSON::Field(key: "content")]
      property content : Content
    end
  end
end
