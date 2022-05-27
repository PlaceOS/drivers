require "placeos-driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "inactive-support/mapped_enum"

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

  private DELIMITER = "\r"

  mapped_enum Command do
    GetStatus   = "getStatus"
    VideoSource = "vidsrc"
    Live        = "live"
    Local       = "local"
    Disable     = "txdisable"
    Mute        = "mute"
    Unmute      = "unmute"
  end

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
  end

  def connected
    schedule.every(50.seconds, true) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def do_poll
    do_send(Command::GetStatus, priority: 0)
  end

  def switch_to(input : Input, **options)
    do_send(Command::VideoSource, input, **options)
  end

  Modes = (1..8).map &.to_s

  def media_source(mode : String)
    if mode == "live"
      do_send(Command::Live)
    elsif Modes.includes?(mode)
      do_send(Command::Local, mode)
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
      do_send(Command::Disable) if layer.audio_video? || layer.video?
      do_send(Command::Mute) if layer.audio_video? || layer.audio?
    else
      do_send(Command::Disable) if layer.audio_video? || layer.video?
      do_send(Command::Unmute) if layer.audio_video? || layer.audio?
    end
  end

  enum Response
    Name
    Stream
    Playmode
    Mute
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    prop, value = data.split(':')

    case Response.parse? prop
    in Response::Name
      self[:device_name] = value
    in Response::Stream
      self[:stream_id] = value.to_i
    in Response::Playmode
      self[:mute] = value == "off"
    in Response::Mute
      self[:audio_mute] = value == "1"
    in Nil
      raise "Invalid response: #{prop}"
    end

    task.try(&.success)
  end

  def do_send(command : Command, *args, **options)
    arguments = [command.mapped_value]

    unless (splat = args.to_a).is_a? Array(NoReturn)
      arguments += splat
    end

    request = "#{arguments.join(':')}#{DELIMITER}"
    send(request, **options)
  end
end
