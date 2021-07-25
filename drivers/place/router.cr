require "future"
require "placeos-driver"

class Place::Router < PlaceOS::Driver
end

require "./router/settings"
require "./router/signal_graph"

class Place::Router < PlaceOS::Driver
  generic_name :Switcher
  descriptive_name "Signal router"
  description "A universal matrix switcher."

  def on_load
    on_update
  end

  def on_update
  end

  # Core routing methods and functionality. This exists as module to enable
  # inclusion in other drivers, such as room logic, that provide auxillary
  # functionality to signal distribution.
  module Core
    alias NodeRef = SignalGraph::Node::Ref

    private getter! siggraph : SignalGraph

    macro included
      def on_update
        load_siggraph
        previous_def
      end
    end

    protected def load_siggraph
      logger.debug { "loading signal graph from settings" }

      SignalGraph.system = system.id

      connections = setting(Settings::Connections::Map, :connections)
      nodes, links, aliases = Settings::Connections.parse connections
      @siggraph = SignalGraph.build nodes, links

      NodeRef::Resolver.clear
      NodeRef::Resolver.merge! aliases

      on_siggraph_load
    end

    protected def on_siggraph_load
      aliases = NodeRef::Resolver.invert
      to_name = ->(ref : NodeRef) { aliases[ref]? || ref.local }
      self[:inputs] = siggraph.inputs.map(&.ref).map(&to_name).to_a
      self[:outputs] = siggraph.outputs.map(&.ref).map(&to_name).to_a
    end

    protected def proxy_for(node : NodeRef)
      case node
      when SignalGraph::Device, SignalGraph::DeviceInput, SignalGraph::DeviceOuput
        proxy_for node.mod
      else
        raise "no device associated with #{node}"
      end
    end

    protected def proxy_for(mod : SignalGraph::Mod)
      (mod.sys == system.id ? system : system mod.sys).get mod.name, mod.idx
    end

    # Routes signal from *input* to *output*.
    def route(input : NodeRef, output : NodeRef)
      logger.info { "requesting route from #{input} to #{output}" }

      path = siggraph.route(input, output) || raise "no route found"

      execs = path.compact_map do |(node, edge, next_node)|
        logger.debug { "#{node} → #{next_node}" }

        raise "#{next_node} is locked, aborting" if next_node.locked

        case edge
        in SignalGraph::Edge::Static
          nil
        in SignalGraph::Edge::Active
          lazy do
            # OPTIMIZE: split this to perform an inital pass to build a hash
            # from Driver::Proxy => [Edge::Active] then form the minimal set of
            # execs that satisfies these.
            mod = proxy_for edge.mod
            res = case func = edge.func
                  in SignalGraph::Edge::Func::Mute
                    mod.mute func.state, func.index
                  in SignalGraph::Edge::Func::Select
                    mod.switch_to func.input
                  in SignalGraph::Edge::Func::Switch
                    mod.switch({func.input => [func.output]})
                  end
            next_node.source = siggraph[input].source
            res
          end
        end
      end

      logger.debug { "found path" }
      execs = execs.to_a

      logger.debug { "running execs" }
      execs = execs.map &.get

      logger.debug { "awaiting responses" }
      # TODO: support timeout on these - maybe run via the driver queue?
      execs = execs.map &.get

      :ok
    end

    # Set mute *state* on *input_or_output*.
    #
    # If the device supports local muting this will be activated, or the closest
    # mute source found and routed.
    def mute(input_or_output : NodeRef, state : Bool = true)
      if state
        route SignalGraph::Mute, input_or_output
      else
        # FIXME: implement unmute. Possible approach: track previous source on
        # each node and restore this.
        raise NotImplementedError.new "unmuting not supported (yet)"
      end
    end

    # Disable signal muting on *input_or_output*.
    def unmute(input_or_output : NodeRef)
      mute input_or_output, false
    end
  end

  include Core
end
