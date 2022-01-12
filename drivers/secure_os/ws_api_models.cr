require "json"

module SecureOS
  abstract class Response
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    use_json_discriminator "type", {
      "state" => StateWrapper,
      "event" => EventWrapper,
      "error" => ErrorWrapper,
    }
  end

  class StateWrapper < Response
    getter type : String = "state"
    getter data : State
  end

  class EventWrapper < Response
    getter type : String = "event"
    getter data : Event
  end

  class ErrorWrapper < Response
    getter type : String = "error"
    getter data : Error
  end

  struct State
    include JSON::Serializable

    getter type : String
    getter id : String | Int64?
    getter ticks : Int64
    getter time : String # "2017-02-02T16:10:07.241"
    getter states : Hash(String, Bool)
  end

  struct Event
    include JSON::Serializable

    getter type : String
    getter id : String | Int64?
    getter action : String
    getter ticks : Int64?
    getter time : String # "2017-02-02T16:10:07.241"
    getter parameters : JSON::Any?
  end

  struct Error
    include JSON::Serializable

    getter request_id : String | Int64?
    getter message : String
    getter error : String
  end
end
