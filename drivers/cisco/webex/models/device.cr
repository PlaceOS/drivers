module Cisco
  module Webex
    module Models
      class Device
        include JSON::Serializable

        @[JSON::Field(key: "webSocketUrl")]
        property websocket_url : String

        @[JSON::Field(key: "name")]
        property name : String?
      end
    end
  end
end
