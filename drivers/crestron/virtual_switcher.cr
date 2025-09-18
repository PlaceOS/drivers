require "placeos-driver"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/muteable"
require "./nvx_models"

class Crestron::VirtualSwitcher < PlaceOS::Driver
  descriptive_name "Crestron Virtual Switcher"
  generic_name :Switcher
  description <<-DESC
    Enumerates the Creston Transmitters and Receivers in a system and provides
    a simple interface for switching between avaiable streams
  DESC

  include Interface::Switchable(String, Int32 | String)
  include Interface::Muteable

  default_settings({
    audio_sink: {
      module_id:     "Mixer_1",
      function_name: "set_string",
      arguments:     ["aes67_control_id"],
      named_args:    {} of String => JSON::Any,
    },
  })

  class AudioSink
    include JSON::Serializable

    getter module_id : String
    getter function_name : String
    getter arguments : Array(JSON::Any) { [] of JSON::Any }
    getter named_args : Hash(String, JSON::Any) { {} of String => JSON::Any }
  end

  @audio : AudioSink? = nil

  def on_update
    @audio = setting?(AudioSink, :audio_sink)
  end

  # dummy to supress errors in routing
  def power(state : Bool)
    state
  end

  protected def switch_audio_to(address : JSON::Any?)
    return unless address
    if sink = @audio
      args = sink.arguments + [address]
      system[sink.module_id].__send__(sink.function_name, args, sink.named_args)
    end
  end

  def transmitters
    system.implementing(Crestron::Transmitter)
  end

  def receivers
    system.implementing(Crestron::Receiver)
  end

  protected def get_streams(input : Input, layer : SwitchLayer = SwitchLayer::All)
    if int_input = input.to_i?
      if int_input == 0
        {"none", JSON::Any.new("")} # disconnected
      else
        # Subtract one as Encoder_1 on the system would be encoder[0] here
        if tx = transmitters[int_input - 1]?
          {tx[:stream_name], tx[:nax_address]?}
        else
          logger.warn { "could not find Encoder_#{input}" }
          nil
        end
      end
    else
      return {input, nil} if layer.video?
      if tx = transmitters.find { |sender| sender[:stream_name]? == input }
        {input, tx[:nax_address]?}
      else
        {input, nil}
      end
    end
  rescue ex
    logger.warn { "could not find Encoder_#{input}, due to '#{ex.message}'" }
    {input, nil}
  end

  # only support muting the outputs, no unmuting
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    return unless state
    switch_layer = case layer
                   in MuteLayer::Audio      then SwitchLayer::Audio
                   in MuteLayer::Video      then SwitchLayer::Video
                   in MuteLayer::AudioVideo then SwitchLayer::All
                   end
    switch({"none" => [index]}, switch_layer)
  end

  def switch_to(input : Input)
    # lookup the input stream
    stream = get_streams(input)
    return unless stream

    switch_audio_to stream[1]
    receivers.switch_to(stream[0])
  end

  def available_inputs
    encoder_name_map.keys
  end

  def available_outputs
    decoder_name_map.keys
  end

  protected def decoder_name_map
    name_map = {} of String => PlaceOS::Driver::Proxy::Driver
    # map-reduce for speed
    Promise.all(receivers.map { |rx|
      Promise.defer { name_map[rx["device_name"].as_s] = rx rescue nil }
    }).get
    name_map
  end

  protected def encoder_name_map
    name_map = {} of String => PlaceOS::Driver::Proxy::Driver
    # map-reduce for speed
    Promise.all(transmitters.map { |tx|
      Promise.defer { name_map[tx["stream_name"].as_s] = tx rescue nil }
    }).get
    name_map
  end

  DUMMY_OUTPUT = [] of Int32

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All

    return unless layer.all? || layer.video? || layer.audio?

    logger.debug { "switching #{layer}: #{map}" }

    connect(map, layer) do |mod, (video, audio)|
      case layer
      in .all?
        switch_audio_to audio
        mod.switch_to(video)
      in .audio?
        switch_audio_to audio
      in .video?
        # the NVX RX implements this interface but the output is ignored
        inp = case video
              in JSON::Any
                video.as_s? || video.as_i
              in String
                video
              end
        mod.switch({inp => DUMMY_OUTPUT}, layer)
      in .data?, .data2?
      end
    end
  end

  private def connect(inouts : Hash(Input, Array(Output)), layer : SwitchLayer, &)
    inouts.each do |input, outputs|
      stream = get_streams(input, layer)
      next unless stream

      outputs = outputs.is_a?(Array) ? outputs : [outputs]
      decoders = receivers
      device_names = nil
      outputs.each do |output|
        case output
        in Int32
          # Subtract one as Decoder_1 on the system would be decoder[0] here
          if decoder = decoders[output - 1]?
            yield(decoder, stream)
          else
            logger.warn { "could not find Decoder_#{output}" }
          end
        in String
          device_names = decoder_name_map unless device_names
          if decoder = device_names[output]?
            yield(decoder, stream)
          else
            logger.warn { "could not find Decoder with name: #{output}" }
          end
        end
      end
    end
  end
end
