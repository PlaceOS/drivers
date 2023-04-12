require "json"

module TwentyFiveLivePro
  module Models
    struct Organization
      include JSON::Serializable

      @[JSON::Field(key: "kind")]
      property kind : String

      @[JSON::Field(key: "id")]
      property id : Int64

      @[JSON::Field(key: "etag")]
      property etag : String

      @[JSON::Field(key: "organizationName")]
      property organization_name : String

      @[JSON::Field(key: "organizationTitle")]
      property organization_title : String?

      @[JSON::Field(key: "organizationTypeId")]
      property organization_type_id : Int64?
    end
  end
end
