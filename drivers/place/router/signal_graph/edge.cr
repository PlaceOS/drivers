require "./mod"

class Place::Router::SignalGraph
  module Edge
    alias Label = Static | Active

    class Static
      class_getter instance : self { new }

      protected def initialize; end
    end

    record Active, mod : Mod, func : Func::Type

    module Func
      record Mute,
        state : Bool,
        index : Int32 | String = 0
        # layer : Int32 | String = "AudioVideo"

      record Select,
        input : Int32 | String

      record Switch,
        input : Int32 | String,
        output : Int32 | String
        # layer :

      # NOTE: currently not supported. Requires interaction via
      # Proxy::RemoteDriver to support dynamic method execution.
      # record Custom,
      #   func : String,
      #   args : Hash(String, JSON::Any::Type)

      macro finished
        alias Type = {{ @type.constants.join(" | ").id }}
      end
    end
  end
end
