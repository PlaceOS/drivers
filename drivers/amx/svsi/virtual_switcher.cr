# This driver provides an abstraction layer for systems using SVSI based signal
# distribution. In place of referencing specific decoders and stream id's,
# this may be used to enable all endpoints associated with a system to be
# grouped as a virtual matrix switcher and a familiar switcher API used.

class Amx::Svsi::VirtualSwitcher < PlaceOS::Driver
  descriptive_name "AMX SVSI Virtual Switcher"
  generic_name :Switcher

  accessor encoders : Array(Encoder)
  accessor decoders : Array(Decoder)

  alias Map = Hash(Int32, Int32 | Array(Int32))

  def switch(signal_map : Map)
    connect(signal_map, :switch)
  end

  def switch_video(signal_map : Map)
    connect(signal_map, :switch_video)
  end

  def switch_audio(signal_map : Map)
    connect(signal_map, :switch_audio)
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
          # TODO
          # decoder.connect_method
        else
          logger.warn { "could not find Decoder_#{output}" }
        end
      end
    end
  end
end
