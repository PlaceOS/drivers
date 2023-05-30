module Cisco
  module Webex
    module Models
      class Event
        include JSON::Serializable

        @[JSON::Field(key: "id")]
        property id : String

        @[JSON::Field(key: "data")]
        property data : Events::Data

        @[JSON::Field(key: "timestamp")]
        property timestamp : Int64

        @[JSON::Field(key: "trackingId")]
        property tracking_id : String

        @[JSON::Field(key: "sequenceNumber")]
        property sequence_number : Int64

        @[JSON::Field(key: "filterMessage")]
        property filter_message : Bool
      end
    end
  end
end
