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
    g[node.id] = Node::Label.new node
  end

  # :ditto:
  protected def insert(node : Node::Mute)
    mute = Node::Label.new node
    mute.source = Mute
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
          func = Edge::Func::Switch.new input.input, output.output, output.layer
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

    if mod.muteable?
      if outputs.empty?
        output = Node::Device.new mod
        func = Edge::Func::Mute.new true
        g[output.id, Mute.id] = Edge::Active.new mod, func
      else
        outputs.each do |output|
          func = Edge::Func::Mute.new true, output.output
          g[output.id, Mute.id] = Edge::Active.new mod, func
        end
      end
    end
  end

  # Construct a graph from a pre-parsed configuration.
  #
  # *nodes* must contain the set of all signal nodes that form the device inputs
  # and outputs across the system. This includes those at the "edge" of the
  # signal network (e.g. a input to a switcher) as well as inputs in use on
  # intermediate devices (e.g. a input on a display, which in turn is attached to
  # the switcher above).
  #
  # *links* declares the interconnections between devices.
  #
  # Modules associated with any of these nodes are then introspected for
  # switching, input selection and mute control based on the interfaces they
  # expose.
  def self.build(nodes : Enumerable(Node::Ref), links : Enumerable({Node::Ref, Node::Ref}))
    mod_io = Hash(Mod, {Set(Input), Set(Output)}).new do |h, k|
      h[k] = {Set(Input).new, Set(Output).new}
    end

    siggraph = new initial_capacity: nodes.size

    siggraph.insert Mute

    # Create verticies for each signal node
    nodes.each do |node|
      siggraph.insert node

      # Track device IO in use for building active edges
      case node
      when Input
        inputs, _ = mod_io[node.mod]
        inputs << node
      when Output
        _, outputs = mod_io[node.mod]
        outputs << node
      end
    end

    # Insert the static edges.
    links.each { |source, dest| siggraph.connect source, dest }

    # Wire up the active edges.
    mod_io.each { |mod, (inputs, outputs)| siggraph.link mod, inputs, outputs }

    # Set a loopback source on all inputs.
    siggraph.inputs.each { |node| node.source = node.ref }

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
  def route(source : Node::Ref, destination : Node::Ref, max_dist = nil)
    path = g.path destination.id, source.id, invert: true

    return nil unless path

    return nil if max_dist && path.size > max_dist

    path.each_cons(2, true).map do |(succ, pred)|
      {
        g[succ],       # source
        g[pred, succ], # edge
        g[pred],       # next node
      }
    end
  end

  # Checks if *node* is a system input.
  def input?(node : Node::Ref) : Bool
    g.sink? node.id
  end

  # Provide the signal nodes that form system inputs.
  def inputs
    # Graph connectivity is inverse to signal direction, hence sinks here.
    g.sinks.compact_map { |id| g[id] unless id == Mute.id }
  end

  # Provide all signal nodes that can be routed to *destination*.
  def inputs(destination : Node::Ref)
    g.subtree(destination.id).map { |id| g[id] }
  end

  # Checks if *node* is a system output.
  def output?(node : Node::Ref) : Bool
    g.source? node.id
  end

  # Provide the signal nodes that form system outputs.
  def outputs
    g.sources.compact_map { |id| g[id] unless id == Mute.id }
  end
end
