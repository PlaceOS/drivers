require "json"

module Aver
  enum AxisSelect
    Pan   = 0
    Tilt
    Zoom
    Focus
  end

  struct Auth
    include JSON::Serializable

    getter token : String
  end

  struct HttpResponse(Data)
    include JSON::Serializable

    getter code : Int32
    getter msg : String
    getter data : Data
  end

  abstract struct Event
    include JSON::Serializable

    getter event : String

    use_json_discriminator "event", {
      "option" => EventOption,
    }
  end

  enum OptionType
    PtzPS
    PtzTS
    PtzZS
  end

  struct Option
    include JSON::Serializable

    getter option : OptionType
    getter value : String
  end

  struct EventOption < Event
    include JSON::Serializable

    getter data : Option
  end
end
