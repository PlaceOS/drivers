module Cisco
  module Webex
    module Models
      class Peek
        include JSON::Serializable

        @[JSON::Field(key: "id")]
        property id : String

        @[JSON::Field(key: "data")]
        property data : Events::Type
      end
    end
  end
end
