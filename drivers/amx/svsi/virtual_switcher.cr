require "placeos-driver/interface/switchable"

# This driver provides an abstraction layer for systems using SVSI based signal
# distribution. In place of referencing specific decoders and stream id's,
# this may be used to enable all endpoints associated with a system to be
# grouped as a virtual matrix switcher and a familiar switcher API used.

class Amx::Svsi::VirtualSwitcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  descriptive_name "AMX SVSI Virtual Switcher"
  generic_name :Switcher

  accessor encoders : Array(Encoder)
  accessor decoders : Array(Decoder)

  alias Map = Hash(Int32, Array(Int32)) | Hash(String, Hash(Int32, Array(Int32)))

  # TODO: no idea how to implement this as
  def switch_to(input : Int32)
  end

  def switch(map : Map)
    case map
    when FullSwitch
      connect(map) do |mod, value|
        mod.switch(value)
      end
    when SelectiveSwitch
      map.each do |layer, inouts|
        next unless layer = SwitchLayer.parse?(layer)
        connect(inouts) do |mod, value|
          mod.switch_audio(value) if layer.audio?
          mod.switch_video(value) if layer.video?
        end
      end
    end
  end

  private def connect(signal_map : Map, &)
    signal_map.each do |input, outputs|
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
