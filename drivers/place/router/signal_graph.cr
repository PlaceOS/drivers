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

  private def initialize(initial_capacity = nil)
    @g = Digraph(Node::Label, Edge::Label).new initial_capacity
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
    if mod.switchable? && !outputs.empty?
      inputs.each do |input|
        outputs.each do |output|
          func = Edge::Func::Switch.new input.input, output.output
          g[output.id, input.id] = Edge::Active.new mod, func
        end
      end
    elsif mod.selectable?
      inputs.each do |input|
        output = Node::Device.new mod
        func = Edge::Func::Select.new input.input
        g[output.id, input.id] = Edge::Active.new mod, func
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
    mod_io = Hash(Mod, {Set(Input), Set(Output)}).new do |h, k|
      h[k] = {Set(Input).new, Set(Output).new}
    end

    siggraph = new initial_capacity: nodes.size

    siggraph.insert Mute

    # Create verticies for each signal node
    nodes.each do |node|
      siggraph.insert node

      # Track device IO in use for building active edges
      inputs, outputs = mod_io[node.mod]
      case node
      when Input
        inputs << node
      when Output
        outputs << node
      end
    end

    # Insert the static edges
    connections.each { |source, dest| siggraph.connect source, dest }

    # Wire up the active edges
    mod_io.each { |mod, (inputs, outputs)| siggraph.link mod, inputs, outputs }

    siggraph
  end

  # Retrieves the labelled state for *node*.
  def [](node : Node::Ref)
    g[node.id]
  end

  # Retrieves the labelled state for the signal node at *node_id*.
  def [](node_id)
    g[node_id]
  end

  # Find the signal path that connects *source* to *dest*, or `nil` if this is
  # not possible.
  #
  # Provides an `Iterator` that provides labels across each node, the edge, and
  # subsequent node.
  def route(source : Node::Ref, destination : Node::Ref)
    path = g.path destination.id, source.id, invert: true

    return nil unless path

    path.each_cons(2, true).map do |(succ, pred)|
      {
        g[succ],       # source
        g[pred, succ], # edge
        g[pred],       # next node
      }
    end
  end

  # Provide the signal nodes that form system inputs.
  def inputs
    # Graph connectivity is inverse to signal direction, hence sinks here.
    g.sinks
  end

  # Provide all signal nodes that can be routed to *destination*.
  def inputs(destination : Node::Ref)
    g.subtree(destination.id)
  end
end
