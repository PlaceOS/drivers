module MuleSoft
  class Booking
    include JSON::Serializable

    @[JSON::Field(key: "unitName")]
    property title : String?

    @[JSON::Field(key: "activityType")]
    property body : String

    @[JSON::Field(key: "unitCode")]
    property recurring_master_id : String?

    @[JSON::Field(key: "startDateTime", converter: MuleSoft::DateTimeConvertor)]
    property event_start : Int64

    @[JSON::Field(key: "endDateTime", converter: MuleSoft::DateTimeConvertor)]
    property event_end : Int64

    property location : String

    # we need this method to create an intermediary hash
    # otherwise when to_json is called all the field names revert to the MuleSoft ones
    def to_placeos
      value = {
        "title"       => @title,
        "body"        => @body,
        "recurring_master_id"   => @recurring_master_id,
        "event_start" => @event_start,
        "event_end"   => @event_end,
        "location"    => @location,
      }
    end
  end

  class BookingResults
    include JSON::Serializable

    property count : Int64

    @[JSON::Field(key: "venueCode")]
    property venue_code : String

    @[JSON::Field(key: "venueName")]
    property venue_name : String

    property bookings : Array(Booking)
  end

  module DateTimeConvertor
    extend self

    def to_json(value, json : JSON::Builder)
      json.string(Time.unix(value).to_local.to_s("%FT%T"))
    end

    def from_json(pull : JSON::PullParser)
      Time.parse(pull.read_string, "%FT%T", Time::Location.local).to_unix
    end
  end
end
