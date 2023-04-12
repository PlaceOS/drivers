require "json"

module TwentyFiveLivePro
  struct Date
    include JSON::Serializable

    @[JSON::Field(key: "startDate", converter: TwentyFiveLivePro::Date::Converter)]
    property start_date : Time

    @[JSON::Field(key: "endDate", converter: TwentyFiveLivePro::Date::Converter)]
    property end_date : Time

    def duration
      end_date - start_date
    end

    module Converter
      extend self

      def to_json(value, json : JSON::Builder)
        json.string(value.to_rfc3339)
      end

      def from_json(value : JSON::PullParser)
        Time.parse_rfc3339(value.read_string)
      end
    end
  end
end
