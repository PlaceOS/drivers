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
    private getter siggraph : SignalGraph { raise "signal graph not initialized" }

    private getter inputs : Hash(String, UInt64) { {} of String => UInt64 }

    private getter outputs : Hash(String, UInt64) { {} of String => UInt64 }

    macro included
      default_settings({
        connections: {} of Nil => Nil,
      })

      def on_update
        previous_def
        connections = setting(Settings::Connections::Map, :connections)
        nodes, links, aliases = Settings::Connections.parse connections, system.id
        @siggraph = SignalGraph.build nodes, links

        # Given a node, provide a string ref to it within this system context.
        local_ref = ->(n : SignalGraph::Node::Ref) do
          aliases.key_for?(n) || n.to_s.lchop("#{system.id}/")
        end

        inodes = nodes.each.select { |n| siggraph.input? n }
        onodes = nodes.each.select { |n| siggraph.output? n }

        @inputs, @outputs = {inodes, onodes}.map do |nodes|
          nodes.map { |n| {local_ref.call(n), n.id} }.to_h
        end

        self[:inputs] = inputs.keys
        self[:outputs] = outputs.keys
      end
    end

    # Routes signal from *input* to *output*.
    def route(input : String, output : String)
      logger.debug { "Requesting route from #{input} to #{output}" }
      "foo"
    end
  end

  include Core
end
