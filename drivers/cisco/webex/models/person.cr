module Cisco
  module Webex
    module Models
      class Person
        include JSON::Serializable

        @[JSON::Field(key: "id")]
        property id : String
      end
    end
  end
end
