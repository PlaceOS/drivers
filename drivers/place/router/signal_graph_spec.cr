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
    def self.module_id?(sys, name, idx)
      mock_id = {sys, name, idx}.hash
      "mod-#{mock_id}"
    end

    def self.driver_metadata?(id)
      m = DriverModel::Metadata.new
      m.implements << Interface::Switchable.to_s
      m.implements << Interface::Mutable.to_s
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
#   Switcher_1: ["*foo", "*bar"]
# }
#
# inputs = {
#   foo: "laptop",
#   bar: "pc"
# }

# Set of inputs in use
# NOTE: alias are only used in the local system, no impact here
ilist = [
  SignalGraph::DeviceInput.new("sys-123", "Display", 1, "hdmi"),
  SignalGraph::DeviceInput.new("sys-123", "Switcher", 1, 1),
  SignalGraph::DeviceInput.new("sys-123", "Switcher", 1, 2)
]

clist = [
  {SignalGraph::DeviceOutput.new("sys-123", "Switcher", 1, 1), SignalGraph::DeviceInput.new("sys-123", "Display", 1, "hdmi")}
]

describe SignalGraph do
  describe ".from_io" do
    it "builds from connections" do
      g = SignalGraph.from_io ilist, clist
    end

    it "raises when parsed an invalid config" do
      expect_raises(ArgumentError) do
        SignalGraph.from_io [] of SignalGraph::DeviceInput, clist
      end
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
