require "placeos-driver/interface/switchable"

# This driver provides an abstraction layer for systems using SVSI based signal
# distribution. In place of referencing specific decoders and stream id's,
# this may be used to enable all endpoints associated with a system to be
# grouped as a virtual matrix switcher and a familiar switcher API used.

class Amx::Svsi::VirtualSwitcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  descriptive_name "AMX SVSI Virtual Switcher"
  generic_name :Switcher

  accessor encoders : Array(Encoder), implementing: InputSelection
  accessor decoders : Array(Decoder), implementing: InputSelection

  def switch_to(input : Int32)
    decoders.each(&.switch_to(input))
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All
    connect(map) do |mod, stream|
      mod.switch_audio(stream) if layer.all? || layer.audio?
      mod.switch_video(stream) if layer.all? || layer.video?
    end
  end

  private def connect(inouts : Hash(Input, Array(Output)), &)
    inouts.each do |input, outputs|
      if input == 0
        stream = 0 # disconnected
      else
        # Subtract one as Encoder_1 on the system would be encoder[0] here
        if encoder = encoders[input - 1]?
          stream = encoder[:stream_id]
        else
          logger.warn { "could not find Encoder_#{input}" }
          break
        end
      end

      outputs = outputs.is_a?(Array) ? outputs : [outputs]
      outputs.each do |output|
        # Subtract one as Decoder_1 on the system would be decoder[0] here
        if decoder = decoders[output - 1]?
          yield(decoder, stream)
        else
          logger.warn { "could not find Decoder_#{output}" }
        end
      end
    end
  end
end
