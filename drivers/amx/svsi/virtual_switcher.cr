require "placeos-driver/interface/switchable"

# This driver provides an abstraction layer for systems using SVSI based signal
# distribution. In place of referencing specific decoders and stream id's,
# this may be used to enable all endpoints associated with a system to be
# grouped as a virtual matrix switcher and a familiar switcher API used.

class Amx::Svsi::VirtualSwitcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(String, Int32)

  descriptive_name "AMX SVSI Virtual Switcher"
  generic_name :Switcher

  accessor encoders : Array(Encoder), implementing: InputSelection
  accessor decoders : Array(Decoder), implementing: InputSelection

  def switch_to(input : String)
    decoders.each(&.switch_to(input.to_i))
  end

  def switch(map : FullSwitch | SelectiveSwitch)
    case map
    when FullSwitch
      connect(map) { |mod, stream| mod.switch_to(stream) }
    when SelectiveSwitch
      map.each do |layer, inouts|
        next unless layer = SwitchLayer.parse?(layer)
        connect(inouts) do |mod, stream|
          mod.switch_audio(stream) if layer.audio?
          mod.switch_video(stream) if layer.video?
        end
      end
    end
  end

  private def connect(inouts : Hash(String, Array(Int32)), &)
    inouts.each do |input, outputs|
      input = input.to_i
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
