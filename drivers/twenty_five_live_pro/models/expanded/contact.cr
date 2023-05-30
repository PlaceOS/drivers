require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct Contact
        include JSON::Serializable

        @[JSON::Field(key: "contactId")]
        property contact_id : Int64?
        @[JSON::Field(key: "etag")]
        property etag : String?
        @[JSON::Field(key: "firstName")]
        property first_name : String?
        @[JSON::Field(key: "familyName")]
        property family_name : String?
        @[JSON::Field(key: "email")]
        property email : String?
      end
    end
  end
end
