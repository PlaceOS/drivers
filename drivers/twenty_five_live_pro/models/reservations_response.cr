require "json"

module TwentyFiveLivePro
  module Models
    struct ReservationsResponse
      include JSON::Serializable

      struct Reservations
        include JSON::Serializable

        @[JSON::Field(key: "engine")]
        property engine : String?

        @[JSON::Field(key: "reservation")]
        property reservation : Array(Reservation)

        @[JSON::Field(field: "pubdate")]
        property pubdate : Date?
      end
    end
  end
end