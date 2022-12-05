require "placeos-driver"
require "placeos-driver/interface/switchable"
require "./nvx_models"

class Crestron::VirtualSwitcher < PlaceOS::Driver
  descriptive_name "Crestron Virtual Switcher"
  generic_name :Switcher
  description <<-DESC
    Enumerates the Creston Transmitters and Receivers in a system and provides
    a simple interface for switching between avaiable streams
  DESC

  include Interface::Switchable(String, Int32 | String)

  def transmitters
    system.implementing(Crestron::Transmitter)
  end

  def receivers
    system.implementing(Crestron::Receiver)
  end

  def switch_to(input : Input)
    # todo need to lookup the input stream
    receivers.switch_to(input)
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

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    # TODO:: allow layered switching
    layer ||= SwitchLayer::All
    return unless layer.all? || layer.video?

    connect(map) do |mod, stream|
      mod.switch_to(stream)
    end
  end

  private def connect(inouts : Hash(Input, Array(Output)), &)
    inouts.each do |input, outputs|
      if int_input = input.to_i?
        if int_input == 0
          stream = 0 # disconnected
        else
          # Subtract one as Encoder_1 on the system would be encoder[0] here
          if tx = transmitters[int_input - 1]?
            stream = tx[:stream_name]
          else
            logger.warn { "could not find Encoder_#{input}" }
            next
          end
        end
      else
        stream = input
      end

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
