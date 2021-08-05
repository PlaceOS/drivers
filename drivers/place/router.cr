require "future"
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
    with _must_ implement the `Switchable`, `InputSelection` or `Mutable` \
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

    private getter! siggraph : SignalGraph

    private getter! resolver : Hash(String, NodeRef)

    macro included
      def on_update
        load_siggraph
        {% if @type.has_method? :on_update %}
          previous_def
        {% end %}
      end
    end

    protected def load_siggraph
      logger.debug { "loading signal graph from settings" }

      connections = setting(Settings::Connections::Map, :connections)
      nodes, links, aliases = Settings::Connections.parse connections, system.id
      @siggraph = SignalGraph.build nodes, links

      @resolver = Hash(String, NodeRef).new do |cache, key|
        cache[key] = NodeRef.resolve key, system.id
      end
      resolver.merge! aliases

      on_siggraph_load
    end

    protected def on_siggraph_load
      aliases = resolver.invert
      to_name = ->(ref : NodeRef) { aliases[ref]? || ref.local(system.id) }

      {% begin %}
        # Read input / output metadata from settings
        {% for io in {:inputs, :outputs} %}
          unless {{io.id}}_config = setting?(Settings::{{io.id.capitalize}}, {{io}})
            # Auto-detect system io if unspecified
            {{io.id}}_config = siggraph.{{io.id}}.map do |node|
              name = to_name.call node.ref
              {name, {"name" => JSON::Any.new name}}
            end.to_h
          end
        {% end %}

        # Expose a list of input keys, along with an `input/<key>` with a hash
        # of metadata and state info for each.
        self[:inputs] = inputs_config.map do |key, meta|
          ref = resolver[key]
          siggraph[ref].watch { |node| self["input/#{key}"] = node }
          siggraph[ref].meta = meta
          key
        end

        # As above, but for the outputs.
        self[:outputs] = outputs_config.map do |key, meta|
          ref = resolver[key]

          # Discover inputs available to each output
          reachable = siggraph.inputs(ref).compact_map do |node|
            name = to_name.call node.ref
            name if inputs_config.has_key? name
          end
          meta["inputs"] = JSON::Any.new reachable.map { |i| JSON::Any.new i }.to_a

          siggraph[ref].watch { |node| self["output/#{key}"] = node }
          siggraph[ref].meta = meta
          key
        end
      {% end %}
    end

    protected def proxy_for(node : NodeRef)
      case node
      when SignalGraph::Device, SignalGraph::Input, SignalGraph::Output
        proxy_for node.mod
      else
        raise "no device associated with #{node}"
      end
    end

    protected def proxy_for(mod : SignalGraph::Mod)
      (mod.sys == system.id ? system : system mod.sys).get mod.name, mod.idx
    end

    # Routes signal from *input* to *output*.
    #
    # Performs all intermediate device interaction based on current system
    # config.
    def route(input : String, output : String)
      logger.debug { "requesting route from #{input} to #{output}" }

      src, dst = resolver.values_at input, output

      path = siggraph.route(src, dst) || raise "no route found"

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
            next_node.source = siggraph[src].source
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
    def mute(input_or_output : String, state : Bool = true)
      logger.debug { "#{state ? "muting" : "unmuting"} #{input_or_output}" }

      ref = resolver[input_or_output]

      proxy_for(ref).mute state

      node = siggraph[ref]
      node.meta["mute"] = JSON::Any.new state
      node.notify

      # TODO: implement graph based muting
      # if state
      #   route "MUTE", input_or_output
      # else
      #   ...
      # end
    end

    # Disable signal muting on *input_or_output*.
    def unmute(input_or_output : String)
      mute input_or_output, false
    end
  end

  include Core
end
