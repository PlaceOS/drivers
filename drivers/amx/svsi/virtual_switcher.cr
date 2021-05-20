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

  alias InputsOutputs = Hash(Int32, Array(Int32))
  # could also do the below instead but that would be confusing
  # alias InputsOutputs = FullSwitch

  def switch_to(input : Int32)
    decoders.each(&.switch(input))
  end

  def switch(map : FullSwitch | SelectiveSwitch)
    case map
    when FullSwitch
      connect(map) { |mod, input| mod.switch(input) }
    when SelectiveSwitch
      map.each do |layer, inouts|
        next unless layer = SwitchLayer.parse?(layer)
        connect(inouts) do |mod, input|
          mod.switch_audio(input) if layer.audio?
          mod.switch_video(input) if layer.video?
        end
      end
    end
  end

  private def connect(inouts : InputsOutputs, &)
    inouts.each do |input, outputs|
      if input == 0
        stream = 0 # disconnected
      else
        if encoder = encoders[input]?
          stream = encoder[:stream_id]
        else
          logger.warn { "could not find Encoder_#{input}" }
          break
        end
      end

      outputs = outputs.is_a?(Array) ? outputs : [outputs]
      outputs.each do |output|
        if decoder = decoders[output]?
          yield(decoder, stream)
        else
          logger.warn { "could not find Decoder_#{output}" }
        end
      end
    end
  end
end
