require "spec"
require "./settings"

alias Settings = Place::Router::Core::Settings
alias SignalGraph = Place::Router::SignalGraph

module PlaceOS::Driver::Proxy::System
  def self.module_id?(sys, name, idx) : String?
    mock_id = {sys, name, idx}.hash
    "mod-#{mock_id}"
  end
end

describe Settings::Connections do
  connections = <<-JSON
    {
      "Display_1": {
        "hdmi": "Switcher_1.1"
      },
      "Switcher_1": ["*Foo", "*Bar"],
      "*FloorBox": "Switcher_1.2"
    }
    JSON

  describe "Map" do
    it "deserializes from JSON" do
      Settings::Connections::Map.from_json connections
    end
  end

  describe ".parse" do
    it "extracts nodes, links, aliases" do
      map = Settings::Connections::Map.from_json connections
      nodes, links, aliases = Settings::Connections.parse map, sys: "abc123"
      nodes.size.should eq(7)
      links.should contain({
        SignalGraph::Output.new("abc123", "Switcher", 1, 1),
        SignalGraph::Input.new("abc123", "Display", 1, "hdmi"),
      })
      aliases.keys.should contain "Foo"
      aliases.keys.should contain "FloorBox"
    end

    it "detects alias conflicts" do
      map = Settings::Connections::Map.from_json <<-JSON
        {
          "Switcher_1": ["*Foo", "*Foo"]
        }
        JSON
      expect_raises(Exception) do
        Settings::Connections.parse map, sys: "abc123"
      end
    end
  end
end
