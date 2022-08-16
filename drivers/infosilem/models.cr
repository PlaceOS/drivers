module Infosilem
  class Event
    include JSON::Serializable

    @[JSON::Field(key: "EventID")]
    property id : String

    @[JSON::Field(key: "EventDescription")]
    property description : String

    @[JSON::Field(key: "StartTime", converter: Infosilem::DateTimeConvertor)]
    property startTime : Time

    @[JSON::Field(key: "EndTime", converter: Infosilem::DateTimeConvertor)]
    property endTime : Time
  end

  module DateTimeConvertor
    extend self

    def to_json(value, json : JSON::Builder)
      json.string(value.to_s("%H:%M:%S"))
    end

    def from_json(pull : JSON::PullParser)
      Time.parse_local("#{Time.local.to_s("%F")} #{pull.read_string}", "%F %H:%M:%S")
    end
  end
end
