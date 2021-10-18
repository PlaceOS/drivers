require "levenshtein"
require "promise"
require "placeos-driver"

class Place::Router < PlaceOS::Driver
end

require "./router/settings"
require "./router/signal_graph"

class Place::Router < PlaceOS::Driver
  generic_name :Switcher
  descriptive_name "Signal router"
  description <<-DESC
    A virtual matrix switcher for arbitrary signal networks.

    Following configuration, this driver can be used to perform simple input → \
    output routing, regardless of intermediate hardware. Drivers it interacts \
    with _must_ implement the `Switchable`, `InputSelection` or `Muteable` \
    interfaces.

    Configuration is specified as a map of devices and their attached inputs. \
    This must exist under a top-level `connections` key.

    Inputs can be either named:

        Display_1:
          hdmi: VidConf_1

    Or, index based:

        Switcher_1:
          - Camera_1
          - Camera_2

    If an input is not a device with an associated module, prefix with an \
    asterisk (`*`) to create a named alias.

        Display_1:
          hdmi: *Laptop

    DESC

  # Core routing methods and functionality. This exists as module to enable
  # inclusion in other drivers, such as room logic, that provide auxillary
  # functionality to signal distribution.
  module Core
    alias NodeRef = SignalGraph::Node::Ref

    # Wrapper for providng simple interaction with a signal node and it's
    # associated driver.
    struct SignalNode
      @label : SignalGraph::Node::Label
      @proxy : Future::Compute(PlaceOS::Driver::Proxy::Driver)

      def initialize(@label, @proxy)
      end

      forward_missing_to @label

      def proxy
        @proxy.get
      end

      def to_s(io)
        io << ref
      end

      def watch(&handler : self ->)
        @label.watch { handler.call self }
      end
    end

    private getter! siggraph : SignalGraph

    private getter! resolver : Hash(String, NodeRef)

    def on_update
      load_siggraph
    end

    protected def load_siggraph
      logger.debug { "loading signal graph from settings" }
      connections = setting(Settings::Connections::Map, :connections)
      load_siggraph connections
    end

    protected def load_siggraph(connections : Settings::Connections::Map)
      nodes, links, aliases = Settings::Connections.parse connections, system.id
      @siggraph = SignalGraph.build nodes, links
      @resolver = init_resolver aliases
      on_siggraph_load
    end

    protected def init_resolver(seed)
      resolver = Hash(String, NodeRef).new(initial_capacity: seed.size) do |cache, key|
        if ref = NodeRef.resolve? key, system.id
          cache[key] = ref
        else
          alt = Levenshtein.find key, cache.keys, 3
          msg = String.build do |err|
            err << %(unknown signal node "#{key}")
            err << %( - did you mean "#{alt}"?) if alt
          end
          raise KeyError.new msg
        end
      end
      resolver.merge! seed
      resolver
    end

    # Reads settings with node metadata into the graph.
    protected def load_io(key : Symbol) : Enumerable(SignalGraph::Node::Label)?
      logger.debug { "loading #{key}" }
      if io = setting?(Settings::IOMeta, key)
        io.map do |(key, meta)|
          ref = resolver[key]
          node = siggraph[ref]
          node.meta = meta
          node
        end
      else
        logger.debug { "no #{key} configured" }
        nil
      end
    end

    protected def on_siggraph_load
      aliases = resolver.invert
      to_name = ->(ref : NodeRef) { aliases[ref]? || ref.local(system.id) }

      inputs = load_io(:inputs) || siggraph.inputs.to_a
      outputs = load_io(:outputs) || siggraph.outputs.to_a

      # Persist previous state across module restarts or settings load
      persist = ->(key : String, node : SignalGraph::Node::Label) do
        self[key]?.try(&.as_h?).try &.each do |attr, value|
          case attr
          when "ref"
            # Ignore
          when "source"
            node.source = signal_node(value.as_s).ref
          when "locked"
            node.locked = value.as_bool
          else
            node[attr] = value
          end
        rescue e
          logger.info(exception: e) { "when loading previous #{key}/#{attr}" }
        end
      end

      # Expose a list of input keys, along with an `input/<key>` with a hash of
      # metadata and state info for each.
      self[:inputs] = inputs.map do |node|
        key = to_name.call node.ref
        persist.call "input/#{key}", node
        node["name"] ||= key
        node.watch { self["input/#{key}"] = node }
        key
      end

      # As above, but for the outputs.
      self[:outputs] = outputs.map do |node|
        key = to_name.call node.ref

        persist.call "output/#{key}", node
        node["name"] ||= key

        # Discover inputs available to each output
        reachable = siggraph.inputs(node.ref).select &.in?(inputs)
        node["inputs"] = reachable.map(&.ref).map(&to_name).to_a

        node.watch { self["output/#{key}"] = node }
        key
      end

      inodes, onodes = {inputs, outputs}.map &.each.map { |n| signal_node n.ref }
      on_siggraph_loaded inodes, onodes
    end

    # Optional callback for overriding by driver extending this.
    protected def on_siggraph_loaded(input, outputs)
    end

    protected def signal_node(key : String)
      ref = resolver[key]
      signal_node ref
    end

    protected def signal_node(ref : NodeRef)
      node = siggraph[ref]

      proxy = lazy do
        case ref
        when SignalGraph::Device, SignalGraph::Input, SignalGraph::Output
          proxy_for ref.mod
        else
          raise "no device associated with #{ref}"
        end
      end

      SignalNode.new node, proxy
    end

    protected def proxy_for(mod : SignalGraph::Mod)
      (mod.sys == system.id ? system : system mod.sys).get mod.name, mod.idx
    end

    # Routes signal from *input* to *output*.
    #
    # Performs all intermediate device interaction based on current system
    # config.
    def route(input : String, output : String, max_dist : Int32? = nil)
      logger.debug { "requesting route from #{input} to #{output}" }

      src, dst = resolver.values_at input, output
      dst_node = siggraph[dst]

      path = siggraph.route(src, dst, max_dist) || raise "no route found"

      execs = path.compact_map do |(node, edge, next_node)|
        logger.debug { "#{node} → #{next_node}" }

        raise "#{next_node} is locked, aborting" if next_node.locked

        case edge
        in SignalGraph::Edge::Static
          nil
        in SignalGraph::Edge::Active
          Promise.defer(same_thread: true, timeout: 1.second) do
            next_node.source = siggraph[src].source

            # OPTIMIZE: split this to perform an inital pass to build a hash
            # from Driver::Proxy => [Edge::Active] then form the minimal set of
            # execs that satisfies these.
            mod = proxy_for edge.mod
            case func = edge.func
            in SignalGraph::Edge::Func::Mute
              mod.mute func.state, func.index
            in SignalGraph::Edge::Func::Select
              mod.switch_to func.input
            in SignalGraph::Edge::Func::Switch
              mod.switch({func.input => [func.output]}, func.layer)
            end
            nil
          end
        end
      end

      # are there any additional switching actions to perform (combined outputs)
      if following_outputs = dst_node["followers"]?.try &.as_a
        logger.debug { "routing #{following_outputs.size} additional followers" }
        following_outputs.each do |output_follow|
          spawn(same_thread: true) { route(input, output_follow.as_s, max_dist) }
        end
      end

      logger.debug { "awaiting responses" }
      execs.each do |promise|
        begin
          promise.get
        rescue error
          logger.warn(exception: error) { "processing route" }
        end
      end

      :ok
    end
  end

  include Core
end
