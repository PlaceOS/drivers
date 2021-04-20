require "set"
require "./digraph"

# Structures and types for mapping between sys,mod,idx,io referencing and the
# underlying graph structure.
#
# The SignalGraph class _does not_ perform any direct interaction with devices,
# but does provide the ability to discover routes and available connectivity
# when may then be acted on.
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

    macro finished
      {% for interface in PlaceOS::Driver::Interface.constants %}
        def {{interface.underscore}}?
          PlaceOS::Driver::Interface::{{interface}}.to_s.in? metadata.implements
        end
      {% end %}
    end

    def_equals_and_hash @id

    def to_s(io)
      io << sys << '/' << name << '_'<< idx
    end
  end

  # Input reference on a device.
  alias Input = Int32 | String

  # Output reference on a device.
  alias Output = Int32 | String

  module Node
    class Label
      property source : UInt64? = nil
      property locked : Bool = false
    end

    abstract struct Ref
      def id
        self.class.hash ^ self.hash
      end
    end

    # Reference to a signal output from a device.
    struct DeviceOutput < Ref
      getter mod : Mod
      getter output : Output

      def initialize(sys, name, idx, @output)
        @mod = Mod.new sys, name, idx
      end

      def to_s(io)
        io << mod << '.' << output
      end
    end

    # Reference to a signal input to a device.
    struct DeviceInput < Ref
      getter mod : Mod
      getter input : Input

      def initialize(sys, name, idx, @input)
        @mod = Mod.new sys, name, idx
      end

      def to_s(io)
        io << mod << '.' << input
      end
    end

    # Virtual node representing (any) mute source
    struct Mute < Ref
      class_getter instance : self { new }
      protected def initialize; end

      def id
        0_u64
      end

      def to_s(io)
        io << "MUTE"
      end
    end
  end

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
        input : Input

      record Switch,
        input : Input,
        output : Output
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

  private def initialize(@graph : Digraph(Node::Label, Edge::Label))
    mute = Node::Mute.instance.id
    @graph[mute] = Node::Label.new.tap &.source = mute
  end

  # Construct a graph from a pre-parsed configuration.
  #
  # *inputs* must contain the list of all device inputs across the system. This
  # include those at the "edge" of the signal network (e.g. a laptop connected
  # to a switcher) as well as inputs in use on intermediate device (e.g. a input
  # on a display, which in turn is attached to the switcher above).
  #
  # *connections* declares the physical links that exist between devices.
  def self.build(inputs : Enumerable(Node::DeviceInput), connections : Enumerable({Node::DeviceOutput, Node::DeviceInput}))
    g = Digraph(Node::Label, Edge::Label).new initial_capacity: connections.size * 2

    m = Hash(Mod, {Set(DeviceInput), Set(DeviceOutput)}).new do |h, k|
      h[k] = {Set(DeviceInput).new, Set(DeviceOutput).new}
    end

    inputs.each do |input|
      # Create a node for the device input
      g[input.id] = Node::Label.new

      # Track the input for active edge creation
      i, _ = m[input.mod]
      i << input
    end

    connections.each do |src, dst|
      # Create a node for the device output
      g[src.id] = Node::Label.new

      # Ensure the input node was declared
      g.fetch(dst.id) do
        raise ArgumentError.new "connection to #{dst} declared, but no matching input exists"
      end

      # Insert a static edge for the  physical link
      g[dst.id, src.id] = Edge::Static.instance

      # Track device outputs for active edge creation
      _, o = m[src.mod]
      o << src
    end

    # Insert active edges
    m.each do |mod, (inputs, outputs)|
      puts mod
      puts inputs.map &.to_s
      puts outputs.map &.to_s

      if mod.switchable?
        Array.each_product(inputs.to_a, outputs.to_a) do |x|
          puts x
        end
      end

      if mod.selectable?
        inputs.each do |input|
          puts input
        end
      end

      if mod.mutable?
        outputs.each do |output|
          #pred = mod.hash
          #!!! Sink.new ???
          #g[mod.hash
        end
      end
    end

    puts g

    new g
  end
end
