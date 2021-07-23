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
    alias Node = SignalGraph::Node::Ref

    private getter siggraph : SignalGraph { raise "signal graph not initialized" }

    private getter inputs : Hash(String, Node) { {} of String => Node }

    private getter outputs : Hash(String, Node) { {} of String => Node }

    macro included
      default_settings({
        connections: {} of Nil => Nil,
      })

      def on_update
        load_siggraph
        previous_def
      end
    end

    protected def load_siggraph
      logger.debug { "loading signal graph from settings" }

      connections = setting(Settings::Connections::Map, :connections)
      nodes, links, aliases = Settings::Connections.parse connections, system.id
      @siggraph = SignalGraph.build nodes, links

      # Given a node, provide a string ref to it within this system context.
      local_ref = ->(n : Node) do
        aliases.key_for?(n) || n.to_s.lchop("#{system.id}/")
      end

      inodes = nodes.each.select { |n| siggraph.input? n }
      onodes = nodes.each.select { |n| siggraph.output? n }

      @inputs, @outputs = {inodes, onodes}.map do |nodes|
        nodes.map { |n| {local_ref.call(n), n} }.to_h
      end

      on_siggraph_load
    end

    protected def on_siggraph_load
    end

    # Routes signal from *input* to *output*.
    def route(input : String, output : String)
      logger.info { "requesting route from #{input} to #{output}" }

      src = inputs[input]
      dst = outputs[output]

      path = siggraph.route(src, dst) || raise "no route from #{src} to #{dst}"

      execs = path.compact_map do |(node, edge, next_node)|
        logger.debug { "#{node} -> #{next_node}" }

        raise "#{next_node} is locked, aborting" if next_node.locked

        case edge
        in SignalGraph::Edge::Static
          nil
        in SignalGraph::Edge::Active
          lazy do
            # OPTIMIZE: split this to perform an inital pass to build a hash
            # from Driver::Proxy => [Edge::Active] then form the minimal set of
            # execs that satisfies these.
            sys = edge.mod.sys == system.id ? system : system(edge.mod.sys)
            mod = sys.get edge.mod.name, edge.mod.idx

            res = case func = edge.func
                  in SignalGraph::Edge::Func::Mute
                    raise NotImplementedError.new "graph based muting unavailable"
                  in SignalGraph::Edge::Func::Select
                    mod.switch_to func.input
                  in SignalGraph::Edge::Func::Switch
                    mod.switch({func.input => [func.output]})
                  end
            next_node.source = node.ref.id
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
  end

  include Core

  protected def on_siggraph_load
    self[:inputs] = inputs.keys
    self[:outputs] = outputs.keys
  end
end
