require "spec"
require "./signal_graph"

alias SignalGraph = Place::Router::SignalGraph

module PlaceOS::Driver::Proxy::System
  def self.module_id?(sys, name, idx)
    "foo"
  end
end

#cmap = {
#  Display_1: {
#    hdmi: "Switcher_1.1"
#  },
#  Switcher_1: ["*Foo", "*Bar"]
#}

clist = [
  {SignalGraph::Source.new("sys-123", "Switcher", 1, 1), SignalGraph::Sink.new("sys-123", "Display", 1, "hdmi")}
]

describe SignalGraph do
  describe ".from_connections" do
    it "builds from a connections map" do
      g = SignalGraph.from_connections clist
    end
  end

  pending "#[]" do
    it "provides node details" do
    end

    it "provides edge details when passed a pair" do
    end
  end

  pending "#route(input, output)" do
    g.route "Switcher_1.1", "Display_1"
    g.route "{1}Switcher_1", "Display_1"
    g.route "Switcher_1-1", "Display_1"
  end

  pending "#inputs" do
    it "provides a list of input nodes within the graph" do
    end
  end

  pending "#inputs(output)" do
    it "provides a list of inputs nodes accessible to an output" do
    end
  end

  pending "#outputs" do
    it "list the output nodes present in the graph" do
    end
  end

  pending "#to_json" do
  end
  pending ".from_json" do
  end

  pending "#merge" do
  end
end
