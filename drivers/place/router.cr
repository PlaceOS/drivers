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

    # Type for representing the settings format for defining connections.
    module Connection
      # Module name of a device within the local system e.g. `"Switcher_1"`.
      alias Device = String

      # Reference to a specific output on a device that has multiple outputs. This
      # is a concatenation of the `Device` reference a `.` and the output. For
      # example, output 3 of Switcher_1 is `"Switcher_1.3"`.
      alias DeviceOutput = String

      # Alias used to refer to a signal node that does not have an accompanying
      # module. This can be useful for declaring the concept of a device that is
      # attached to an input (e.g. `"Laptop"`) that can later used as a reference
      # for SignalGraph interactions.
      alias Alias = String

      # The device a signal is originating from.
      alias Source = Device | DeviceOutput | Alias

      # The device that recieves the signal.
      alias Sink = Device | Alias

      # Identifier for the input on Sink.
      alias Input = String

      # Structure for a full connection map.
      #
      # ```json
      # {
      #   "Display_1": {
      #     "hdmi": "Switcher_1.1"
      #   },
      #   "Switcher_1: ["Foo", "Bar"]
      # }
      # ```
      alias Map = Hash(Sink, Hash(Input, Source) | Array(Source) | Source)
    end

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
