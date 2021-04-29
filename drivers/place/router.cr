require "json"
require "placeos-driver"
require "placeos-driver/interface/switchable"

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
    # Setting loaded from `Core`.
  end

  # Core routing methods and functionality. This exists as module to enable
  # inclusion in other drivers, such as room logic, that provide auxillary
  # functionality to signal distribution.
  module Core

    # NOTE: possible nice pattern for compulsory callbacks
    # abstract def on_route

    # Types for representing the settings format for defining connections.
    module Connection
      module Deserializable
        def new(pull : JSON::PullParser)
          parse?(pull.read_string) || pull.raise
        end

        def from_json_object_key?(key : String)
          parse? key
        end
      end

      # Module name of a device within the local system e.g. `"Switcher_1"`.
      record Device, mod : String, idx : Int32 do
        extend Deserializable

        def self.parse?(raw : String)
          mod, idx = raw.split '_'
          idx = (idx || 1).to_i? || return nil
          new mod, idx
        end
      end


      # Reference to a specific output on a device that has multiple outputs.
      # This is a concatenation of the `Device` reference a `.` and the output.
      # For example, output 3 of Switcher_1 is `"Switcher_1.3"`.
      record DeviceOutput, mod : String, idx : Int32, output : String | Int32 do
        extend Deserializable

        def self.parse?(raw : String)
          mod, idx = raw.split '_'
          idx, output = idx.split '.'
          idx = (idx || 1).to_i?
          if mod.presence && idx && output.presence
            new mod, idx, output
          else
            nil
          end
        end
      end

      # Alias used to refer to a signal node that does not have an accompanying
      # module. This can be useful for declaring the concept of a device that is
      # attached to an input (e.g. `"*Laptop"`). All alias' must be prefixed with
      # an asterisk ('*') within connections settings.
      record Alias, name : String do
        extend Deserializable

        def self.parse?(raw : String)
          if name = raw.lchop?('*')
            new name
          else
            nil
          end
        end
      end

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
      #   "Switcher_1: ["*Foo", "*Bar"]
      # }
      # ```
      alias Map = Hash(Sink, Hash(Input, Source) | Array(Source) | Source)
    end

    getter siggraph : SignalGraph { raise "signal graph not initialized" }

    private def build_siggraph(connections : Connection::Map)
      nodes = [] of SignalGraph::Node::Ref
      links = [] of {SignalGraph::Node::Ref, SignalGraph::Node::Ref}
      aliases = {} of String => SignalGraph::Node::Ref

      connections.each do |sink, inputs|
        if sink.starts_with? '*'
          raise NotImplementedError.new "output aliases are not supported (#{sink})"
        else
          #sink_node = 
        end
      end

      @siggraph = SignalGraph.build nodes, links
    end

    macro included
      def on_update
        previous_def
        build_siggraph setting(Connection::Map, :connections)
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
