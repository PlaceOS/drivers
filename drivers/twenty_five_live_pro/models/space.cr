require "json"

module TwentyFiveLivePro
  module Models
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

      @[JSON::Field(key: "canRequest")]
      property can_request : Bool
    end
  end
end
