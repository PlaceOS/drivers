require "json"

module TwentyFiveLivePro
  module Models
    struct Reservation
      include JSON::Serializable

      @[JSON::Field(key: "reservation_id")]
      property reservation_id : Int64

      @[JSON::Field(key: "event_title")]
      property event_title : String?

      @[JSON::Field(key: "reservation_start_dt" )]
      property reservation_start_dt : String

      @[JSON::Field(key: "reservation_end_dt")]
      property reservation_end_dt : String

      @[JSON::Field(key: "registered_count")]
      property registered_count : Int64?
    end
  end
end