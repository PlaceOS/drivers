require "placeos-driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "inactive-support/mapped_enum"

# Documentation: https://aca.im/driver_docs/AMX/SVSIN1000N2000Series.APICommandList.pdf

class Amx::Svsi::NSeriesDecoder < PlaceOS::Driver
  include Interface::Muteable
  include PlaceOS::Driver::Interface::InputSelection(Int32)

  tcp_port 50002
  descriptive_name "AMX SVSI N-Series Decoder"
  generic_name :Decoder

  @previous_stream : Int32? = nil
  @mute : Bool = false
  @stream : Int32? = nil

  private DELIMITER = "\r"

  mapped_enum Command do
    GetStatus     = "getStatus"
    Set           = "set"
    SetSettings   = "setSettings"
    SwitchKVM     = "KVMMasterIP"
    Mute          = "mute"
    Unmute        = "unmute"
    SetAudio      = "seta"
    Live          = "live"
    Local         = "local"
    ScalerEnable  = "scalerenable"
    ScalerDisable = "scalerdisable"
    ModeSet       = "modeset"
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

  def switch_to(input : Int32)
    switch_video(input)
    switch_audio(0) # enable AFV
  end

  def switch_video(stream_id : Int32)
    do_send(Command::Set, stream_id)
  end

  def switch_audio(stream_id : Int32)
    @previous_stream = stream_id
    unmute
  end

  def switch_kvm(ip_address : String, video_follow : Bool = true)
    host = "#{ip_address},#{video_follow ? 1 : 0}"
    do_send(Command::SwitchKVM, host)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    if state
      do_send(Command::Mute, name: :mute)
      do_send(Command::SetAudio, 0)
    else
      do_send(Command::SetAudio, @previous_stream || 0)
      do_send(Command::Unmute, name: :mute)
    end
  end

  def live(state : Bool = true)
    state ? do_send(Command::Live) : local(self[:playlist].as_i)
  end

  def local(playlist : Int32 = 0)
    do_send(Command::Local, playlist)
  end

  def scaler(state : Bool)
    action = state ? Command::ScalerEnable : Command::ScalerDisable
    do_send(action, name: :scaler)
  end

  OutputModes = [
    "auto",
    "1080p59.94",
    "1080p60",
    "720p60",
    "4K30",
    "4K25",
  ]

  def output_resolution(mode : String)
    unless OutputModes.includes?(mode)
      logger.error { "\"#{mode}\" is not a valid resolution" }
      return
    end
    do_send(Command::ModeSet, mode)
  end

  def videowall(
    width : Int32,
    height : Int32,
    x_pos : Int32,
    y_pos : Int32,
    scale : VideowallScalingMode = VideowallScalingMode::Auto
  )
    if width > 1 && height > 1
      videowall_size(width, height)
      videowall_position(x_pos, y_pos)
      videowall_scaling(scale)
      videowall_enable
    else
      videowall_disable
    end
  end

  def videowall_enable(state : Bool = true)
    state = state ? "on" : "off"
    do_send(Command::SetSettings, "wallEnable", state)
  end

  def videowall_disable
    videowall_enable(false)
  end

  def videowall_size(width : Int32, height : Int32)
    do_send(Command::SetSettings, "wallHorMons", width)
    do_send(Command::SetSettings, "wallVerMons", height)
  end

  def videowall_position(x : Int32, y : Int32)
    do_send(Command::SetSettings, "wallMonPosV", x)
    do_send(Command::SetSettings, "wallMonPosH", y)
  end

  enum VideowallScalingMode
    Auto    # decoder decides best method
    Fit     # aspect distort
    Stretch # fill and crop
  end

  def videowall_scaling(scaling_mode : VideowallScalingMode)
    do_send(Command::SetSettings, "wallStretch", scaling_mode)
  end

  mapped_enum Response do
    Stream       = "stream"
    StreamAudio  = "streamaudio"
    Name         = "name"
    Playmode     = "playmode"
    Playlist     = "playlist"
    Mute         = "mute"
    ScalerBypass = "scalerbypass"
    Mode         = "mode"
    InputRes     = "inputres"
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    prop, value = data.split(':')

    case Response.from_mapped_value?(prop.downcase)
    in Response::Stream
      self[:video] = @stream = value.to_i
    in Response::StreamAudio
      stream_id = value.to_i
      self[:audio_actual] = stream_id
      self[:audio] = stream_id == 0 ? (@mute ? 0 : @stream) : stream_id
    in Response::Name
      self[:device_name] = value
    in Response::Playmode
      self[:local_playback] = value == "local"
    in Response::Playlist
      self[:playlist] = value.to_i
    in Response::Mute
      self[:mute] = @mute = value == "1"
    in Response::ScalerBypass
      self[:scaler_active] = value != "no"
    in Response::Mode
      self[:output_res] = value
    in Response::InputRes
      self[:input_res] = value
    in Nil
      raise "Unexpected response: #{prop}"
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
