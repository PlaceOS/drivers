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

  alias Device = Node::Device

  Mute = Node::Mute.instance

  private getter g : Digraph(Node::Label, Edge::Label)

  private def initialize(digraph)
    @g = digraph
    insert Mute
  end

  # Inserts *node*.
  protected def insert(node : Node::Ref)
    g[node.id] = Node::Label.new
  end

  # :ditto:
  protected def insert(node : Node::Mute)
    mute = Node::Label.new
    mute.source = Mute.id
    mute.locked = true
    g[node.id] = mute
  end

  # Defines a physical connection between two devices.
  #
  # *output* and *input* must both already exist within the underlying graph as
  # signal nodes.
  protected def connect(output : Node::Ref, input : Node::Ref)
    g[input.id, output.id] = Edge::Static.instance
  end

  # Given a *mod* and sets of known *inputs* and *outputs* in use on it, wire up
  # any active edges between these based on the interfaces available.
  protected def link(mod : Mod, inputs : Enumerable(Input), outputs : Enumerable(Output))
    if mod.switchable?
      inputs.each do |input|
        outputs.each do |output|
          func = Edge::Func::Switch.new input.input, output.output
          g[output.id, input.id] = Edge::Active.new mod, func
        end
      end
    end

    outputs = {Node::Device.new mod} if outputs.empty?

    if mod.selectable?
      inputs.each do |input|
        outputs.each do |output|
          func = Edge::Func::Select.new input.input
          g[output.id, input.id] = Edge::Active.new mod, func
        end
      end
    end

    if mod.mutable?
      outputs.each do |output|
        func = Edge::Func::Mute.new true
        g[output.id, Mute.id] = Edge::Active.new mod, func
      end
    end
  end

  # Construct a graph from a pre-parsed configuration.
  #
  # *nodes* must contain the set of all signal nodes that form the device inputs
  # and ouputs across the system. This includes those at the "edge" of the
  # signal network (e.g. a input to a switcher) as well as inputs in use on
  # intermediate device (e.g. a input on a display, which in turn is attached to
  # the switcher above).
  #
  # *connections* declares the physical links that exist between these.
  #
  # Modules associated with any of these nodes are then introspected for
  # switching, input selection and mute control based on the interfaces they
  # expose.
  def self.build(nodes : Enumerable(Node::Ref), connections : Enumerable({Node::Ref, Node::Ref}))
    g = new Digraph(Node::Label, Edge::Label).new initial_capacity: nodes.size

    m = Hash(Mod, {Set(Input), Set(Output)}).new do |h, k|
      h[k] = {Set(Input).new, Set(Output).new}
    end

    # Create verticies for each signal node
    nodes.each do |node|
      g.insert node

      # Track device IO in use for building active edges
      i, o = m[node.mod]
      case node
      when Input
        i << node
      when Output
        o << node
      end
    end

    # Insert the static edges
    connections.each { |src, dst| g.connect src, dst }

    # Wire up the active edges
    m.each { |mod, (inputs, outputs)| g.link mod, inputs, outputs }

    g
  end
end
