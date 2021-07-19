require "json"
require "./signal_graph"

module Place::Router::Settings
  # Types for representing the settings format for defining connections.
  module Connections
    module Deserializable
      macro extended
        def self.new(pull : JSON::PullParser)
          parse?(pull.read_string) || pull.raise("Invalid #{self} (#{pull.string_value.inspect})")
        end
      end

      abstract def parse?(raw : String)

      def from_json_object_key?(key : String)
        parse? key
      end
    end

    # Module name of a device within the local system e.g. `"Switcher_1"`.
    record Device, mod : String, idx : Int32 do
      extend Deserializable

      PATTERN = /^([a-z]+)\_(\d+)$/i

      def self.parse?(raw : String)
        if m = raw.match PATTERN
          mod = m[1]
          idx = m[2].to_i
          new mod, idx
        end
      end
    end

    # Reference to a specific output on a device that has multiple outputs.
    # This is a concatenation of the `Device` reference a `.` and the output.
    # For example, output 3 of Switcher_1 is `"Switcher_1.3"`.
    record DeviceOutput, mod : String, idx : Int32, output : String | Int32 do
      extend Deserializable

      PATTERN = /^([a-z]+)\_(\d+)\.(.+)$/i

      def self.parse?(raw : String)
        if m = raw.match PATTERN
          mod = m[1]
          idx = m[2].to_i
          output = m[3].to_i? || m[3]
          new mod, idx, output
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
    alias Sink = Device

    # Identifier for the input on Sink.
    alias Input = String

    # Structure for a full connection map.
    #
    # ```json
    # {
    #   "Display_1": {
    #     "hdmi": "Switcher_1.1"
    #   },
    #   "Switcher_1": ["*Foo", "*Bar"]
    # }
    # ```
    alias Map = Hash(Sink, Hash(Input, Source) | Array(Source))

    # Parses a `Map` containing the system conectivity into a set of signal
    # graph nodes, links and aliases.
    def self.parse(map : Map, sys : String)
      nodes = [] of SignalGraph::Node::Ref
      links = [] of {SignalGraph::Node::Ref, SignalGraph::Node::Ref}
      aliases = {} of String => SignalGraph::Node::Ref

      map.each do |sink, inputs|
        nodes << SignalGraph::Device.new sys, sink.mod, sink.idx

        # Iterate source arrays as 1-based input id's
        inputs = inputs.each.with_index(1).map &.reverse if inputs.is_a? Array

        inputs.each do |input, source|
          inode = SignalGraph::Input.new sys, sink.mod, sink.idx, input
          nodes << inode

          if source.is_a? Alias
            aliases[source.name] = inode
            next
          end

          onode = case source
                  in Device
                    SignalGraph::Device.new sys, source.mod, source.idx
                  in DeviceOutput
                    SignalGraph::Output.new sys, source.mod, source.idx, source.output
                  end
          nodes << onode

          links << {onode, inode}
        end
      end

      {nodes, links, aliases}
    end
  end
end
