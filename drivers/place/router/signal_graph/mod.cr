require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Place::Router::SignalGraph
  # Reference to a PlaceOS module that provides IO nodes within the graph.
  class Mod
    getter sys : String
    getter name : String
    getter idx : Int32

    getter id : String

    def initialize(@sys, @name, @idx)
      id = PlaceOS::Driver::Proxy::System.module_id? sys, name, idx
      @id = id || raise %("#{name}/#{idx}" does not exist in #{sys})
    end

    def metadata
      if meta = PlaceOS::Driver::Proxy::System.driver_metadata?(id)
        meta
      else
        # TODO:: warn about offline device
        PlaceOS::Driver::DriverModel::Metadata.new(interface: {} of String => Hash(String, JSON::Any))
      end
    rescue error
      raise RuntimeError.new("failed to obtain metadata for #{id}", cause: error)
    end

    # FIXME: drop if / after renaming InputSelection -> Selectable
    def selectable?
      interface = {{PlaceOS::Driver::Interface::InputSelection.name(generic_args: false).stringify}}
      interface.in? metadata.implements
    end

    macro finished
      {% for interface in PlaceOS::Driver::Interface.constants %}
        {% type = PlaceOS::Driver::Interface.constant(interface) %}
        def {{interface.underscore}}?
          {{type.name(generic_args: false).stringify}}.in? metadata.implements
        end
      {% end %}
    end

    def_equals_and_hash @id

    def to_s(io)
      io << sys << '/' << name << '_' << idx
    end

    def self.parse?(ref)
      if m = ref.match /^(.+)\/(.+)\_(\d+)$/
        sys = m[1]
        mod = m[2]
        idx = m[3].to_i
        new sys, mod, idx
      end
    end
  end
end
