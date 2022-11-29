module Cisco
  module Webex
    module Models
      module Events
        class Actor
          include JSON::Serializable

          @[JSON::Field(key: "id")]
          property id : String

          @[JSON::Field(key: "objectType")]
          property object_type : String

          @[JSON::Field(key: "displayName")]
          property display_name : String

          @[JSON::Field(key: "orgId")]
          property organization_id : String

          @[JSON::Field(key: "emailAddress")]
          property email : String

          @[JSON::Field(key: "entryUUID")]
          property entry_uuid : String

          @[JSON::Field(key: "type")]
          property type : String
        end
      end
    end
  end
end
