require "set"
require "./digraph"
require "./signal_graph/*"

# Structures and types for mapping between sys,mod,idx,io referencing and the
# underlying graph structure.
#
# The SignalGraph class _does not_ perform any direct interaction with devices,
# but does provide the ability to discover routes and available connectivity
# when may then be acted on.
class Place::Router::SignalGraph
  alias Input = Node::DeviceInput

  alias Output = Node::DeviceOutput

  Mute = Node::Mute.instance

  private def initialize(@graph : Digraph(Node::Label, Edge::Label))
    @graph[Mute.id] = Node::Label.new.tap &.source = Mute.id
  end

  # Construct a graph from a pre-parsed configuration.
  #
  # *inputs* must contain the list of all device inputs across the system. This
  # include those at the "edge" of the signal network (e.g. a laptop connected
  # to a switcher) as well as inputs in use on intermediate device (e.g. a input
  # on a display, which in turn is attached to the switcher above).
  #
  # *connections* declares the physical links that exist between devices.
  def self.build(inputs : Enumerable(Input), connections : Enumerable({Output, Input}))
    g = Digraph(Node::Label, Edge::Label).new initial_capacity: connections.size * 2

    m = Hash(Mod, {Set(Input), Set(Output)}).new do |h, k|
      h[k] = {Set(Input).new, Set(Output).new}
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

      # Ensure the input node was declared previously
      g.fetch(dst.id) do
        raise ArgumentError.new "connection to #{dst} declared, but no matching input exists"
      end

      # Insert a static edge for the  physical link
      g[dst.id, src.id] = Edge::Static.instance

      # Track device output for active edge creation
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
