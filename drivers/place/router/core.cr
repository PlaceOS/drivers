require "placeos-driver"
require "levenshtein"
require "promise"

require "./settings"
require "./signal_graph"

# Core routing methods and functionality. This exists as module to enable
# inclusion in other drivers, such as room logic, that provide auxillary
# functionality to signal distribution.
module Place::Router::Core
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
  def route_signal(input : String, output : String, max_dist : Int32? = nil, simulate : Bool = false, follow_additional_routes : Bool = true)
    logger.debug { "requesting route from #{input} to #{output}" }

    src, dst = resolver.values_at input, output
    dst_node = siggraph[dst]
    src_node = siggraph[src]

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
          if !simulate
            mod = proxy_for edge.mod
            case func = edge.func
            in SignalGraph::Edge::Func::Mute
              # check if we want to mute a video or audio layer
              dst_layer = dst_node.ref.layer.downcase
              case dst_layer
              when "audio", "video"
                mod.mute func.state, func.index, dst_layer
              else
                mod.mute func.state, func.index
              end
            in SignalGraph::Edge::Func::Select
              mod.switch_to func.input
            in SignalGraph::Edge::Func::Switch
              mod.switch({func.input => [func.output]}, func.layer)
            end
          end
          nil
        end
      end
    end

    # are there any additional switching actions to perform (combined outputs)
    if follow_additional_routes
      routes = {} of String => Tuple(String, String, Int32?, Bool, Bool)

      if following_outputs = dst_node["followers"]?.try(&.as_a)
        logger.debug { "routing #{following_outputs.size} additional followers" }
        following_outputs.each { |output_follow| routes[output_follow.as_s] = {input, output_follow.as_s, max_dist, simulate, false} }
      end

      ignore_source_routes = dst_node["ignore_source_routes"]?.try(&.as_bool) || false

      # perform_routes: {output: input}
      if !ignore_source_routes && (additional_routes = src_node["perform_routes"]?.try(&.as_h))
        logger.debug { "perfoming #{additional_routes.size} additional routes" }
        additional_routes.each { |ad_output, ad_input| routes[ad_output] = {ad_input.as_s, ad_output, max_dist, simulate, false} }
      end

      spawn(same_thread: true) {
        routes.each_value { |route| route_signal(*route) }
      }
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
