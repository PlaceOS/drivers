require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/AMX/SVSIN1000N2000Series.APICommandList.pdf

class Amx::Svsi::NSeriesEncoder < PlaceOS::Driver
  include Interface::Muteable

  enum Input
    Hdmionly
    Vgaonly
    Hdmivga
    Vgahdmi
  end

  include Interface::InputSelection(Input)

  tcp_port 50002
  descriptive_name "AMX SVSI N-Series Encoder"
  generic_name :Encoder

  def on_load
    # 0x0D (<CR> carriage return \r)
    transport.tokenizer = Tokenizer.new(Bytes[0x0D])
  end

  def connected
    schedule.every(50.seconds, true) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def do_poll
    do_send("getStatus", priority: 0)
  end

  def switch_to(input : Input, **options)
    do_send("vidsrc", input, **options)
  end

  Modes = ["1", "2", "3", "4", "5", "6", "7", "8"]

  def media_source(mode : String)
    if mode == "live"
      do_send("live")
    elsif Modes.includes?(mode)
      do_send("local", mode)
    else
      raise("invalid mode #{mode}")
    end
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    if state
      do_send("txdisable") if layer.audio_video? || layer.video?
      do_send("mute") if layer.audio_video? || layer.audio?
    else
      do_send("txdisable") if layer.audio_video? || layer.video?
      do_send("unmute") if layer.audio_video? || layer.audio?
    end
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    prop, value = data.split(':')

    case prop.downcase
    when "name",
         self[:device_name] = value
    when "stream"
      self[:stream_id] = value.to_i
    when "playmode"
      self[:mute] = value == "off"
    when "mute"
      self[:audio_mute] = value == "1"
    end

    task.try(&.success)
  end

  def do_send(*args, **options)
    command = "#{args.join(':')}\r"
    send(command, **options)
  end
end
