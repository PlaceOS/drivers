abstract class PlaceOS::Driver; end

require "spec"
require "placeos-driver/driver_model"
require "./signal_graph"

alias SigGraph = Place::Router::SignalGraph

abstract class PlaceOS::Driver
  module Interface
    module Switchable; end

    module Selectable; end

    module Muteable; end

    # TODO: expand interfaces in `placeos-driver` to cover this
    module InputMuteable; end
  end

  class Proxy::System
    def self.module_id?(sys, name, idx) : String?
      mock_id = {sys, name, idx}.hash
      "mod-#{mock_id}"
    end

    def self.driver_metadata?(id) : DriverModel::Metadata?
      m = DriverModel::Metadata.new
      m.implements << {{Interface::Switchable.name(generic_args: false).stringify}}
      m.implements << {{Interface::Selectable.name(generic_args: false).stringify}}
      m.implements << {{Interface::Muteable.name(generic_args: false).stringify}}
      m
    end
  end
end

# Settings:
#
# connections = {
#   Display_1: {
#     hdmi: "Switcher_1.1"
#   },
#   Switcher_1: ["*foo", "*bar"],
#   Display_2: {
#     hdmi: "*baz"
#   }
# }
#
# inputs = {
#   foo: "laptop",
#   bar: "pc"
# }

# Set of inputs in use
# NOTE: alias are only used in the local system, no impact here
nodes = [
  SigGraph::Input.new("sys-123", "Display", 1, "hdmi"),
  SigGraph::Input.new("sys-123", "Display", 2, "hdmi"),
  SigGraph::Input.new("sys-123", "Switcher", 1, 1),
  SigGraph::Input.new("sys-123", "Switcher", 1, 2),
  SigGraph::Output.new("sys-123", "Switcher", 1, 1),
  SigGraph::Device.new("sys-123", "Display", 1),
  SigGraph::Device.new("sys-123", "Display", 2),
  SigGraph::Device.new("sys-123", "Switcher", 1),
]

connections = [
  {SigGraph::Output.new("sys-123", "Switcher", 1, 1), SigGraph::Input.new("sys-123", "Display", 1, "hdmi")},
]

inputs = {
  foo: SigGraph::Input.new("sys-123", "Switcher", 1, 1),
  bar: SigGraph::Input.new("sys-123", "Switcher", 1, 2),
  baz: SigGraph::Input.new("sys-123", "Display", 2, "hdmi"),
}

outputs = {
  display:  SigGraph::Device.new("sys-123", "Display", 1),
  display2: SigGraph::Device.new("sys-123", "Display", 2),
}

describe SigGraph do
  describe ".build" do
    it "builds from config" do
      SigGraph.build nodes, connections
    end
  end

  describe "#[]" do
    n = SigGraph::Device.new("sys-123", "Display", 1)
    g = SigGraph.build [n], [] of {SigGraph::Node::Ref, SigGraph::Node::Ref}

    it "provides node details from a Ref" do
      g[n].should be_a(SigGraph::Node::Label)
    end

    it "provides nodes details from an ID" do
      g[n.id].should be_a(SigGraph::Node::Label)
    end

    it "provides the same label for both accessors" do
      g[n].should eq(g[n.id])
    end
  end

  describe "#route" do
    g = SigGraph.build nodes, connections

    it "returns nil if no path exists" do
      path = g.route inputs[:foo], outputs[:display2]
      path.should be_nil
    end

    it "provides the path connects a signal source to a destination" do
      source = inputs[:foo]
      dest = outputs[:display]

      path = g.route source, dest
      path = path.not_nil!

      path.each_with_index do |(node, edge, next_node), step|
        case step
        when 0
          node.should eq g[source]
          edge = edge.as SigGraph::Edge::Active
          edge.mod.name.should eq "Switcher"
          edge.func.should eq SigGraph::Edge::Func::Switch.new 1, 1
        when 1
          edge.should be_a SigGraph::Edge::Static
          next_node.should eq g[SigGraph::Input.new("sys-123", "Display", 1, "hdmi")]
        when 2
          edge = edge.as SigGraph::Edge::Active
          edge.mod.name.should eq "Display"
          edge.mod.idx.should eq 1
          edge.func.should eq SigGraph::Edge::Func::Select.new "hdmi"
        when 4
          fail "path iterator did not terminate"
        end
      end
    end

    it "provides mute activation on an output device" do
      source = SigGraph::Mute
      dest = outputs[:display]

      path = g.route source, dest
      path = path.not_nil!

      node, edge, next_node = path.first
      node.should eq g[source]
      edge = edge.as SigGraph::Edge::Active
      edge.mod.name.should eq "Display"
      edge.func.should eq SigGraph::Edge::Func::Mute.new true
      next_node.should eq g[dest]
    end

    it "provide mute activate on an intermediate switcher" do
      source = SigGraph::Mute
      dest = SigGraph::Output.new("sys-123", "Switcher", 1, 1)

      path = g.route source, dest
      path = path.not_nil!

      node, edge, next_node = path.first
      node.should eq g[source]
      edge = edge.as SigGraph::Edge::Active
      edge.mod.name.should eq "Switcher"
      edge.func.should eq SigGraph::Edge::Func::Mute.new true, 1
      next_node.should eq g[dest]
    end
  end

  describe "#input?" do
    g = SigGraph.build nodes, connections

    it "returns true if the node is an input" do
      g.input?(inputs.values.sample).should be_true
    end

    it "returns false otherwise" do
      g.input?(outputs.values.sample).should be_false
    end
  end

  describe "#inputs" do
    it "provides a list of input nodes within the graph" do
      g = SigGraph.build nodes, connections
      expected = inputs.values
      discovered = g.inputs.map(&.ref).to_a
      expected.each { |input| discovered.should contain input }
    end
  end

  describe "#inputs(destination)" do
    it "provides a list of inputs nodes accessible to an output" do
      g = SigGraph.build nodes, connections
      reachable = g.inputs(outputs[:display]).map(&.ref).to_a
      expected = {inputs[:foo], inputs[:bar]}
      expected.each { |input| reachable.should contain input }
    end
  end

  describe "#output?" do
    g = SigGraph.build nodes, connections

    it "returns true if the node is an output" do
      g.output?(outputs.values.sample).should be_true
    end

    it "returns false otherwise" do
      g.output?(inputs.values.sample).should be_false
    end
  end

  describe "#outputs" do
    it "list the output nodes present in the graph" do
      g = SigGraph.build nodes, connections
      expected = outputs.values
      discovered = g.outputs.map(&.ref).to_a
      expected.each { |output| discovered.should contain output }
    end
  end

  pending "#to_json" do
  end
  pending ".from_json" do
  end

  pending "#merge" do
  end

  describe SigGraph::Node::Label do
    it "supports change notification" do
      n = SigGraph::Device.new("sys-123", "Display", 1)
      g = SigGraph.build [n], [] of {SigGraph::Node::Ref, SigGraph::Node::Ref}

      x = 0

      g[n].watch(initial: false) { x += 1 }

      x.should eq 0
      g[n].notify
      x.should eq 1

      g[n].locked.should be_false
      g[n].locked = true
      x.should eq 2
      g[n].locked.should be_true
    end
  end
end
