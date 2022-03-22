module Cisco
  module Webex
    module Models
      module Events
        class Target
          include JSON::Serializable

          @[JSON::Field(key: "id")]
          property id : String

          @[JSON::Field(key: "objectType")]
          property object_type : String

          @[JSON::Field(key: "url")]
          property url : String

          @[JSON::Field(key: "published")]
          property published : String
        end
      end
    end
  end
end
