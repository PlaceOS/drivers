require "spec"
require "./digraph"

alias Digraph = Place::Router::Digraph

describe Digraph do
  g = Digraph(String, String).new

  describe "node insertion / retrieval" do
    it "inserts a node with the specified ID" do
      g[42] = "foo"
      g[42].should eq("foo")
    end

    it "raises when inserting on ID conflict" do
      expect_raises(Digraph::Error) do
        g[42] = "foo"
        g[42] = "bar"
      end
    end

    it "raises when retrieving if node does not exist" do
      expect_raises(Digraph::Error) do
        g[123]
      end
    end
  end

  describe "edge insertion / retrieval" do
    it "inserts between the specified IDs" do
      g[0] = "foo"
      g[1] = "bar"
      g[0, 1] = "foobar"
      g[0, 1].should eq("foobar")
    end

    it "raises if setting an edge that already exists" do
      expect_raises(Digraph::Error) do
        g.insert(0, "foo") { }
        g.insert(1, "bar") { }
        g[0, 1] = "foobar"
        g[0, 1] = "foobar"
      end
    end

    it "raises when reading an edge that does not exist" do
      expect_raises(Digraph::Error) do
        g[1, 0]
      end
    end
  end

  describe "#path" do
    it "works on a trival graph" do
      g = Digraph(String, String).new
      g[0] = "a"
      g[1] = "b"
      g[2] = "c"
      g[0, 1] = "ab"
      g[1, 2] = "bc"
      g.path(0, 2).should eq([0, 1, 2])
      g.path(2, 0).should be_nil
    end

    it "finds the shortest path" do
      g = Digraph(String, String).new
      g[0] = "a"
      g[1] = "b"
      g[2] = "c"
      g[0, 1] = "ab"
      g[1, 2] = "bc"

      g[3] = "x"
      g[4] = "y"
      g[5] = "z"
      g[0, 3] = "ax"
      g[3, 4] = "xy"
      g[4, 5] = "yz"
      g[5, 2] = "zc"

      g.path(0, 2).should eq([0, 1, 2])
    end
  end

  describe "#nodes" do
    it "provides a node Iterator" do
      g = Digraph(String, String).new
      g[0] = "a"
      g[1] = "b"
      g[2] = "c"
      g.nodes.should be_a(Iterator(UInt64))
      (g.nodes.to_a - [0, 1, 2]).should be_empty
    end
  end

  describe "#outdegree" do
    it "count outgoing edges" do
      g = Digraph(String, String).new
      g[0] = "a"
      g[1] = "b"
      g[0, 1] = "ab"
      g.outdegree(0).should eq(1)
      g.outdegree(1).should eq(0)
    end
  end
end
