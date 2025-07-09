require "placeos-driver"
require "placeos-driver/interface/switchable"
require "./models"

# This driver provides an abstraction layer for systems using SVSI based signal
# distribution. In place of referencing specific receivers and stream id's,
# this may be used to enable all endpoints associated with a system to be
# grouped as a virtual matrix switcher and a familiar switcher API used.

class Amx::Svsi::VirtualSwitcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  descriptive_name "AMX SVSI Virtual Switcher"
  generic_name :Switcher

  private def transmitters
    system.implementing(Amx::Transmitter)
  end

  private def receivers
    system.implementing(Amx::Receiver)
  end

  def switch_to(input : Int32)
    receivers.each(&.switch_to(input))
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All
    connect(map) do |mod, stream|
      mod.switch_audio(stream) if layer.all? || layer.audio?
      mod.switch_video(stream) if layer.all? || layer.video?
    end
  end

  def encoder_count
    transmitters.size
  end

  def decoder_count
    receivers.size
  end

  private def connect(inouts : Hash(Input, Array(Output)), &)
    inouts.each do |input, outputs|
      if input == 0
        stream = 0 # disconnected
      else
        # Subtract one as Encoder_1 on the system would be encoder[0] here
        if encoder = transmitters[input - 1]?
          stream = encoder[:stream_id]
        else
          logger.warn { "could not find Encoder_#{input}" }
          break
        end
      end

      outputs = outputs.is_a?(Array) ? outputs : [outputs]
      outputs.each do |output|
        # Subtract one as Decoder_1 on the system would be decoder[0] here
        if decoder = receivers[output - 1]?
          yield(decoder, stream)
        else
          logger.warn { "could not find Decoder_#{output}" }
        end
      end
    end
  end
end
