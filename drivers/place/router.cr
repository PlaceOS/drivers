require "placeos-driver"

class Place::Router < PlaceOS::Driver
end

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
    # TODO: load connections config
  end

  # Core routing methods and functionality. This exists as module to enable
  # inclusion in other drivers, such as room logic, that provide auxillary
  # functionality to signal distribution.
  module Core
    @siggraph = Digraph(SignalNode, EdgeActivation?).new

    # NOTE: possible nice pattern for compulsory callbacks
    # abstract def on_route

    # Routes signal from *input* to *output*.
    def route(input : String, output : String)
      logger.debug { "Requesting route from #{input} to #{output}" }

      input_id = node_id input
      output_id = node_id output

      path = @siggraph.path(output_id, input_id)
      raise "No route possible from #{input} to #{output}" if path.nil?

      logger.debug { "Found path via #{path.reverse.join(" -> ", &.name)}" }
      # TODO: activate edges

      "foo"
    end
  end
  include Core
end
