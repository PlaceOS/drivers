require "json"

module SecureOS
  enum StateType
    Attached
    Armed
    Alarmed
  end

  struct SubscribeRule
    include JSON::Serializable

    getter type : String
    getter id : String
    getter states : Array(StateType)? = nil
    getter events : Array(String)? = nil
    getter action : Symbol

    def initialize(
      @type : String,
      @id : String,
      @action : Symbol,
      @states : Array(StateType)? = nil,
      @events : Array(String)? = nil
    )
    end
  end

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

    @[JSON::Field(converter: Time::Format.new("%FT%T.%L", Time::Location::UTC))]
    getter time : Time # "2017-02-02T16:10:07.241"

    getter states : Hash(String, Bool)
  end

  struct Event
    include JSON::Serializable

    getter type : String
    getter id : String | Int64?
    getter action : String
    getter ticks : Int64?

    @[JSON::Field(converter: Time::Format.new("%FT%T.%L", Time::Location::UTC))]
    getter time : Time # "2017-02-02T16:10:07.241"

    getter parameters : JSON::Any?
  end

  struct Error
    include JSON::Serializable

    getter request_id : String | Int64?
    getter message : String
    getter error : String
  end

  struct AuthResponse
    include JSON::Serializable

    getter data : AuthToken
    getter status : String
  end

  struct AuthToken
    include JSON::Serializable

    getter token : String
  end

  struct CameraResponse
    include JSON::Serializable

    getter data : Array(Camera)
    getter status : String
  end

  struct Camera
    include JSON::Serializable

    getter id : String
    getter name : String
    getter settings : JSON::Any
    getter status : JSON::Any
    getter type : String
  end

  struct WatchlistResponse
    include JSON::Serializable

    getter data : Array(Watchlist)
    getter status : String
  end

  struct Watchlist
    include JSON::Serializable

    getter id : String
    getter name : String
  end
end
