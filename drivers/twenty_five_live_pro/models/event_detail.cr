require "json"
require "./expanded/**"

module TwentyFiveLivePro
  module Models
    struct EventDetail
      include JSON::Serializable

      struct Content
        include JSON::Serializable

        @[JSON::Field(key: "id")]
        property id : Int64?

        @[JSON::Field(key: "updated")]
        property updated : String?

        struct Data
          include JSON::Serializable

          struct Event
            include JSON::Serializable

            @[JSON::Field(key: "kind")]
            property kind : String

            @[JSON::Field(key: "id")]
            property id : Int64

            @[JSON::Field(key: "etag")]
            property etag : String

            @[JSON::Field(key: "name")]
            property name : String

            @[JSON::Field(key: "eventLocator")]
            property event_locator : String

            @[JSON::Field(key: "priority")]
            property priority : Int64

            @[JSON::Field(key: "updated")]
            property updated : String

            @[JSON::Field(key: "dates")]
            property date : Date
          end

          @[JSON::Field(key: "items")]
          property items : Array(Event)
        end

        @[JSON::Field(key: "data")]
        property data : Data

        struct ExpandedInfo
          include JSON::Serializable

          @[JSON::Field(key: "organizations")]
          property organizations : Array(Expanded::Organization)?

          @[JSON::Field(key: "attributes")]
          property attributes : Array(Expanded::Attribute)?

          @[JSON::Field(key: "roles")]
          property roles : Array(Expanded::Role)?

          @[JSON::Field(key: "spaces")]
          property spaces : Array(Expanded::Space)?

          @[JSON::Field(key: "resources")]
          property resources : Array(Expanded::Resource)?

          @[JSON::Field(key: "states")]
          property states : Array(Expanded::State)?

          @[JSON::Field(key: "eventTypes")]
          property event_types : Array(Expanded::EventType)?

          @[JSON::Field(key: "parentNodes")]
          property parent_nodes : Array(Expanded::ParentNode)?

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
