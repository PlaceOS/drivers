require "placeos-driver"

class Place::Router < PlaceOS::Driver
end

require "./router/settings"
require "./router/signal_graph"

class Place::Router < PlaceOS::Driver
  generic_name :Switcher
  descriptive_name "Signal router"
  description <<-DESC
    A universal matrix switcher.
    DESC

  def on_load
    on_update
  end

  def on_update
  end

  # Core routing methods and functionality. This exists as module to enable
  # inclusion in other drivers, such as room logic, that provide auxillary
  # functionality to signal distribution.
  module Core

    # NOTE: possible nice pattern for compulsory callbacks
    # abstract def on_route

    getter siggraph : SignalGraph { raise "signal graph not initialized" }

    macro included
      def on_update
        connections = setting(Settings::Connections::Map, :connections)
        nodes, links, aliases = Settings::Connections.parse connections, system.id
        @siggraph = SignalGraph.build nodes, links
      end
    end

    # Routes signal from *input* to *output*.
    def route(input : String, output : String)
      logger.debug { "Requesting route from #{input} to #{output}" }
      "foo"
    end
  end

  include Core
end
