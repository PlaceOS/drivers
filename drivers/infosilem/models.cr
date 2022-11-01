module Infosilem
  class Event
    include JSON::Serializable

    @[JSON::Field(key: "EventID")]
    property id : String

    @[JSON::Field(key: "EventDescription")]
    property description : String?

    @[JSON::Field(key: "NumberOfAttendees", converter: Infosilem::IntegerConverter)]
    property number_of_attendees : Int32?

    @[JSON::Field(key: "OccurrenceIsConflicting", converter: Infosilem::IntegerConverter)]
    property conflicting : Int32?

    @[JSON::Field(key: "StartTime", converter: Infosilem::DateTimeConvertor)]
    property start_time : Time

    @[JSON::Field(key: "EndTime", converter: Infosilem::DateTimeConvertor)]
    property end_time : Time

    property container : Bool?

    def duration
      end_time - start_time
    end
  end

  module DateTimeConvertor
    extend self

    def to_json(value, json : JSON::Builder)
      json.string(value.to_s("%H:%M:%S"))
    end

    def from_json(value : JSON::PullParser)
      Time.parse_local("#{Time.local.to_s("%F")} #{value.read_string}", "%F %H:%M:%S")
    end
  end

  module IntegerConverter
    extend self

    def to_json(value, json : JSON::Builder)
      json.string(value.to_s)
    end

    def from_json(value : JSON::PullParser)
      value.read_string.to_i
    end
  end
end
