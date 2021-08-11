require "placeos-driver"
require "placeos-driver/interface/powerable"

class Place::Meet < PlaceOS::Driver
  generic_name :System
  descriptive_name "Meeting room logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction with devices, systems \
    and integrations found within common workplace collaboration spaces.
    DESC
end

require "./router"

class Place::Meet < PlaceOS::Driver
  include Router::Core

  protected def on_siggraph_loaded(inputs, outputs)
    outputs.each &.watch { |node| on_output_change node }
  end

  protected def on_output_change(output)
    case output.source
    when nil
      output.proxy.power false
    when Router::SignalGraph::Mute
      # nothing to do here
    else
      output.proxy.power true
    end
  end

  def powerup
    logger.debug { "Powering up" }
    self[:active] = true
  end

  def shutdown
    logger.debug { "Shutting down" }
    system.implementing(PlaceOS::Driver::Interface::Powerable).power false
    self[:active] = false
  end

  # Set the volume of a signal node within the system.
  def volume(input_or_output : String, level : Int64)
    logger.info { "setting volume on #{input_or_output} to #{level}" }
    node = signal_node input_or_output
    node.proxy.volume level
    node["volume"] = level
  end
end
