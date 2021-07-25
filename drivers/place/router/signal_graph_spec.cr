require "spec"
require "placeos-driver/driver_model"
require "./signal_graph"

alias SignalGraph = Place::Router::SignalGraph

module PlaceOS::Driver
  module Interface
    module Switchable; end

    module Selectable; end

    module Mutable; end

    module InputMutable; end
  end

  module Proxy::System
    def self.module_id?(sys, name, idx) : String?
      mock_id = {sys, name, idx}.hash
      "mod-#{mock_id}"
    end

    def self.driver_metadata?(id) : DriverModel::Metadata?
      m = DriverModel::Metadata.new
      m.implements << {{Interface::Switchable.name(generic_args: false).stringify}}
      m.implements << {{Interface::Selectable.name(generic_args: false).stringify}}
      m.implements << {{Interface::Mutable.name(generic_args: false).stringify}}
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
  SignalGraph::Input.new("sys-123", "Display", 1, "hdmi"),
  SignalGraph::Input.new("sys-123", "Display", 2, "hdmi"),
  SignalGraph::Input.new("sys-123", "Switcher", 1, 1),
  SignalGraph::Input.new("sys-123", "Switcher", 1, 2),
  SignalGraph::Output.new("sys-123", "Switcher", 1, 1),
  SignalGraph::Device.new("sys-123", "Display", 1),
  SignalGraph::Device.new("sys-123", "Display", 2),
  SignalGraph::Device.new("sys-123", "Switcher", 1),
]

connections = [
  {SignalGraph::Output.new("sys-123", "Switcher", 1, 1), SignalGraph::Input.new("sys-123", "Display", 1, "hdmi")},
]

inputs = {
  foo: SignalGraph::Input.new("sys-123", "Switcher", 1, 1),
  bar: SignalGraph::Input.new("sys-123", "Switcher", 1, 2),
  baz: SignalGraph::Input.new("sys-123", "Display", 2, "hdmi"),
}

outputs = {
  display:  SignalGraph::Device.new("sys-123", "Display", 1),
  display2: SignalGraph::Device.new("sys-123", "Display", 2),
}

describe SignalGraph do
  describe ".build" do
    it "builds from config" do
      SignalGraph.build nodes, connections
    end
  end

  describe "#[]" do
    n = SignalGraph::Device.new("sys-123", "Display", 1)
    g = SignalGraph.build [n], [] of {SignalGraph::Node::Ref, SignalGraph::Node::Ref}

    it "provides node details from a Ref" do
      g[n].should be_a(SignalGraph::Node::Label)
    end

    it "provides nodes details from an ID" do
      g[n.id].should be_a(SignalGraph::Node::Label)
    end

    it "provides the same label for both accessors" do
      g[n].should eq(g[n.id])
    end
  end

  describe "#route" do
    g = SignalGraph.build nodes, connections

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
          edge = edge.as SignalGraph::Edge::Active
          edge.mod.name.should eq "Switcher"
          edge.func.should eq SignalGraph::Edge::Func::Switch.new 1, 1
        when 1
          edge.should be_a SignalGraph::Edge::Static
          next_node.should eq g[SignalGraph::Input.new("sys-123", "Display", 1, "hdmi")]
        when 2
          edge = edge.as SignalGraph::Edge::Active
          edge.mod.name.should eq "Display"
          edge.mod.idx.should eq 1
          edge.func.should eq SignalGraph::Edge::Func::Select.new "hdmi"
        when 4
          fail "path iterator did not terminate"
        end
      end
    end
  end

  describe "#input?" do
    g = SignalGraph.build nodes, connections

    it "returns true if the node is an input" do
      g.input?(inputs.values.sample).should be_true
    end

    it "returns false otherwise" do
      g.input?(outputs.values.sample).should be_false
    end
  end

  describe "#inputs" do
    it "provides a list of input nodes within the graph" do
      g = SignalGraph.build nodes, connections
      expected = inputs.values
      discovered = g.inputs.map(&.ref).to_a
      expected.each { |input| discovered.should contain input }
    end
  end

  describe "#inputs(destination)" do
    it "provides a list of inputs nodes accessible to an output" do
      g = SignalGraph.build nodes, connections
      reachable = g.inputs(outputs[:display]).map(&.ref).to_a
      expected = {inputs[:foo], inputs[:bar]}
      expected.each { |input| reachable.should contain input }
    end
  end

  describe "#output?" do
    g = SignalGraph.build nodes, connections

    it "returns true if the node is an output" do
      g.output?(outputs.values.sample).should be_true
    end

    it "returns false otherwise" do
      g.output?(inputs.values.sample).should be_false
    end
  end

  describe "#outputs" do
    it "list the output nodes present in the graph" do
      g = SignalGraph.build nodes, connections
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
end
