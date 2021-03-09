require "./digraph"

class Place::Router::SignalGraph
  @graph : Digraph(Node, Edge::Type)

  delegate clear, to: @graph

  private def initialize(@graph)
  end

  def self.build(&)
    graph = Digraph(Node, Edge::Type).new
    yield graph
    new graph
  end

  # Resolve a *mod* reference to it's fully qualified ID.
  #
  # ```
  # resolve("sys-abc123", "Display_1") # => "mod-xyz456"
  # ```
  private def self.resolve(sys : String, mod : String) : String
    return mod if mod.starts_with? "mod-"
    name, idx = Proxy::RemoteDriver.get_parts mod
    id = Proxy::System.module_id? sys, name, idx
    id || raise ArgumentError.new %("#{mod}" does not exist in #{sys})
  end

  # Provides the node ID for the passed *ref*.
  #
  # Node ref's take one of the following forms:
  # 1. `mod{output}`, which denotes a signal output from a device
  # 2. `{input}mod`, for signal inputs
  # 3. `mod`, for a devices central / default signal node
  #
  # This resolves the embedded module reference, rebuilds into the original
  # form and provide the ID for routing operations.
  def self.node_id(sys : String, ref : String) : UInt64
    if ref[0] == '{'
      input, mod = ref[1..].split '}'
      "{#{input}}#{resolve sys, mod}".hash
    elsif ref[-1] == '}'
      mod, output = ref[..-2].split '{'
      "#{resolve sys, mod}{#{output}}".hash
    else
      resolve(ref).hash
    end
  end

  def self.from_connections(connections : Enumerable({String, String}), sys : String)
    build do |g|
      connections.each do |source, dest|
        src = node_id sys, source
        dst = node_id sys, dest
        g[src] = Node.new source
        g[dst] = Node.new dest
        g[dst, src] = Edge::Static.instance
      end
    end
  end

  def self.new(pull : JSON::PullParser)
    raise NotImplementedError.new
  end

  def to_json(builder : JSON::Builder)
    raise NotImplementedError.new
  end

  class Node
    getter ref : String
    property source : UInt64? = nil
    property locked : Bool = false
    def initialize(@ref); end
  end

  module Edge
    alias Type = Static | Active

    class Static
      class_getter instance : Static { Static.new }
      private def initialize; end
    end

    record Active,
      sys : String,
      mod : String,
      func : Func::Type

    module Func
      record Mute,
        state : Bool,
        index : Int32 | String = 0
        # layer : Int32 | String = "AudioVideo"

      record Switch,
        input : Int32 | String

      record Route,
        input : Int32 | String,
        output : Int32 | String
        # layer : 

      # NOTE: currently not supported. Requires interaction via
      # Proxy::RemoteDriver to support dynamic method execution.
      #record Custom,
      #  func : String,
      #  args : Hash(String, JSON::Any::Type)

      macro finished
        alias Type = {{ @type.constants.join(" | ").id }}
      end
    end
  end
end
