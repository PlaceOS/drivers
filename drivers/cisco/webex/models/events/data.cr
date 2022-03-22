module Cisco
  module Webex
    module Models
      module Events
        class Data
          include JSON::Serializable

          @[JSON::Field(key: "activity")]
          property activity : Activity

          @[JSON::Field(key: "eventType")]
          property event_type : String
        end
      end
    end
  end
end
