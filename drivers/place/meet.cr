require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

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
  include Interface::Muteable
  include Interface::Powerable
  include Router::Core

  def on_update
    self[:name] = system.name

    load_siggraph
  end

  protected def on_siggraph_loaded(inputs, outputs)
    outputs.each &.watch { |node| on_output_change node }
  end

  protected def on_output_change(output)
    case output.source
    when Router::SignalGraph::Mute, nil
      # nothing to do here
    else
      output.proxy.power true
    end
  end

  # Sets the overall room power state.
  def power(state : Bool)
    return if state == self[:active]?
    logger.debug { "Powering #{state ? "up" : "down"}" }
    self[:active] = state

    if state
      # no action - devices power on when signal is routed
    else
      system.implementing(Interface::Powerable).power false
    end
  end

  # Set the volume of a signal node within the system.
  def volume(level : Int32, input_or_output : String)
    logger.info { "setting volume on #{input_or_output} to #{level}" }
    node = signal_node input_or_output
    node.proxy.volume level
    node["volume"] = level
  end

  # Sets the mute state on a signal node within the system.
  def mute(state : Bool = true, input_or_output : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    # Int32's accepted for Muteable interface compatibility
    unless input_or_output.is_a? String
      raise ArgumentError.new("invalid input or output reference: #{input_or_output}")
    end

    logger.debug { "#{state ? "muting" : "unmuting"} #{input_or_output} #{layer}" }

    node = signal_node input_or_output

    case layer
    in .audio?
      node.proxy.audio_mute(state).get
      node["mute"] = state
    in .video?
      node.proxy.video_mute(state).get
      node["video_mute"] = state
    in .audio_video?
      node.proxy.mute(state).get
      node["mute"] = state
      node["video_mute"] = state
    end
  end
end
