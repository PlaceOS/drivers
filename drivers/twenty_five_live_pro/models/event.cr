require "json"

module TwentyFiveLivePro
  module Models
    struct Event
      include JSON::Serializable

      @[JSON::Field(key: "kind")]
      property kind : String

      @[JSON::Field(key: "id")]
      property id : Int64

      @[JSON::Field(key: "etag")]
      property etag : String

      @[JSON::Field(key: "eventName")]
      property name : String

      @[JSON::Field(key: "eventTitle")]
      property title : String?

      @[JSON::Field(key: "eventLocator")]
      property event_locator : String

      @[JSON::Field(key: "updated")]
      property updated : String

      @[JSON::Field(key: "dates")]
      property date : Date

      property container : Bool?
    end
  end
end
