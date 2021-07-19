require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Place::Router::SignalGraph
  # Reference to a PlaceOS module that provides IO nodes within the graph.
  private class Mod
    getter sys : String
    getter name : String
    getter idx : Int32

    getter id : String

    def initialize(@sys, @name, @idx)
      id = PlaceOS::Driver::Proxy::System.module_id? sys, name, idx
      @id = id || raise %("#{name}/#{idx}" does not exist in #{sys})
    end

    def metadata
      PlaceOS::Driver::Proxy::System.driver_metadata?(id).not_nil!
    end

    # FIXME: drop if / after renaming InputSelection -> Selectable
    def selectable?
       PlaceOS::Driver::Interface::InputSelection.to_s.in? metadata.implements
    end

    macro finished
      {% for interface in PlaceOS::Driver::Interface.constants %}
        def {{interface.underscore}}?
          PlaceOS::Driver::Interface::{{interface}}.to_s.in? metadata.implements
        end
      {% end %}
    end

    def_equals_and_hash @id

    def to_s(io)
      io << sys << '/' << name << '_' << idx
    end
  end
end
