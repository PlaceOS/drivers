require "./digraph"

# Structure for mapping between sys,mod,idx,io referencing and the underlying
# graph structure. The SignalGraph class _does not_ perform any direct
# interaction with devices, but does provide the ability to discover routes and
# available connectivity.
class Place::Router::SignalGraph
  # Reference to a PlaceOS module that forms part of the graph.
  private class Mod
    getter sys  : String
    getter name : String
    getter idx  : Int32

    def initialize(@sys, @name, @idx)
    end

    def id : String
      id = PlaceOS::Driver::Proxy::System.module_id? sys, name, idx
      id || raise %("#{name}/#{idx}" does not exist in #{sys})
    end

    def metadata
      PlaceOS::Driver::Proxy::System.driver_metadata?(id).not_nil!
    end

    def switchable?
      PlaceOS::Driver::Interface::InputSelection.to_s.in? metadata.implements
    end

    def routable?
      PlaceOS::Driver::Interface::Switchable.to_s.in? metadata.implements
    end

    def mutable?
      PlaceOS::Driver::Interface::Mutable.to_s.in? metadata.implements
    end

    def hash(hasher)
      id.hash hasher
    end
  end

  # Input reference on a device.
  alias Input = Int32 | String

  # Output reference on a device.
  alias Output = Int32 | String

  # Reference to a signal source eminating from a device.
  record Source, mod : Mod, output : Output do
    def initialize(sys, name, idx, @output)
      @mod = Mod.new sys, name, idx
    end
  end

  # Reference to a signal sink (device input).
  record Sink, input : Input, mod : Mod do
    def initialize(sys, name, idx, @input)
      @mod = Mod.new sys, name, idx
    end
  end

  # Node labels containing the metadata to track at each vertex.
  class Node
    property source : UInt64? = nil
    property locked : Bool = false
  end

  module Edge
    # Edge label for storing associated behaviour.
    alias Type = Static | Active

    class Static
      class_getter instance : Static { Static.new }
      protected def initialize; end
    end

    record Active, mod : Mod, func : Func::Type

    module Func
      record Mute,
        state : Bool,
        index : Int32 | String = 0
        # layer : Int32 | String = "AudioVideo"

      record Switch,
        input : Input

      record Route,
        input : Input
        output : Output
        # layer : 

      # NOTE: currently not supported. Requires interaction via
      # Proxy::RemoteDriver to support dynamic method execution.
      #record Custom,
      #  func : String,
      #  args : Hash(String, JSON::Any::Type)

      macro finished
        alias Type = {{ @type.constants.join(" | ").id }}
      end
    end
  end

  # Virtual node representing (any) mute source
  Mute = Node.new

  @graph : Digraph(Node, Edge::Type)

  private def initialize(@graph)
    @graph[0] = Mute
  end

  # Construct a graph from a set `Source` -> `Sink` pairs that declare the
  # physical connectivity of the system.
  def self.from_connections(connections : Enumerable({Source, Sink}))
    g = Digraph(Node, Edge::Type).new initial_capacity: connections.size

    m = Hash(Mod, {i: Array(Input), o: Array(Output)}).new do |h, k|
      h[k] = {i: [] of Input, o: [] of Output}
    end

    connections.each do |src, dst|
      pred = dst.hash
      succ = src.hash
      g[pred] = Node.new
      g[succ] = Node.new
      g[succ, pred] = Edge::Static.instance

      m[src.mod][:o] << src.output
      m[dst.mod][:i] << dst.input
    end

    # TODO create active edges

    new g
  end
end
