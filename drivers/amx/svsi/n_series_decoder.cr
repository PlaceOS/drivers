require "placeos-driver/interface/muteable"

# Documentation: https://aca.im/driver_docs/AMX/SVSIN1000N2000Series.APICommandList.pdf

class Amx::Svsi::NSeriesDecoder < PlaceOS::Driver
  include Interface::Muteable

  tcp_port 50002
  descriptive_name "AMX SVSI N-Series Decoder"
  generic_name :Decoder

  @previous_stream : Int32? = nil
  @mute : Bool = false
  @stream : Int32? = nil

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

  def switch(stream_id : Int32)
    do_send("set", stream_id)
    switch_audio(0) # enable AFV
  end

  def switch_video(stream_id : Int32)
    do_send("set", stream_id)
  end

  def switch_audio(stream_id : Int32)
    @previous_stream = stream_id
    unmute
  end

  def switch_kvm(ip_address : String, video_follow : Bool = true)
    host = "#{ip_address},#{video_follow ? 1 : 0}"
    do_send("KVMMasterIP", host)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    if state
      do_send("mute", name: :mute)
      do_send("seta", 0)
    else
      do_send("seta", @previous_stream || 0)
      do_send("unmute", name: :mute)
    end
  end

  def live(state : Bool = true)
    state ? do_send("live") : local(self[:playlist].as_i)
  end

  def local(playlist : Int32 = 0)
    do_send("local", playlist)
  end

  def scaler(state : Bool)
    action = state ? "scalerenable" : "scalardisable"
    do_send(action, name: :scaler)
  end

  OutputModes = [
    "auto",
    "1080p59.94",
    "1080p60",
    "720p60",
    "4K30",
    "4K25"
  ]
  def output_resolution(mode : String)
    unless OutputModes.includes?(mode)
      logger.error { "\"#{mode}\" is not a valid resolution" }
      return
    end
    do_send("modeset", mode)
  end

  def videowall(
    width : Int32,
    height : Int32,
    x_pos : Int32,
    y_pos : Int32,
    scale : VideowallScalingMode = VideowallScalingMode:: Auto
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
    do_send("setSettings", "wallEnable", state)
  end

  def videowall_disable
    videowall_enable(false)
  end

  def videowall_size(width : Int32, height : Int32)
    do_send("setSettings", "wallHorMons", width)
    do_send("setSettings", "wallVerMons", height)
  end

  def videowall_position(x : Int32, y : Int32)
    do_send("setSettings", "wallMonPosV", x)
    do_send("setSettings", "wallMonPosH", y)
  end

  enum VideowallScalingMode
    Auto    # decoder decides best method
    Fit     # aspect distort
    Stretch # fill and crop
  end

  def videowall_scaling(scaling_mode : VideowallScalingMode)
    do_send("setSettings", "wallStretch", scaling_mode)
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    prop, value = data.split(':')

    case prop
    when "stream"
      self[:video] = @stream = value.to_i
    when "streamaudio"
      stream_id = value.to_i
      self[:audio_actual] = stream_id
      self[:audio] = stream_id == 0 ? (@mute ? 0 : @stream) : stream_id
    when "name",
      self[:device_name] = value
    when "playmode"
      self[:local_playback] = value == "local"
    when "playlist"
      self[:playlist] = value.to_i
    when "mute"
      self[:mute] = @mute = value == "1"
    when "scalerbypass"
      self[:scaler_active] = value != "no"
    when "mode"
      self[:output_res] = value
    when "inputres"
      self[:input_res] = value
    end

    task.try(&.success)
  end

  def do_send(*args, **options)
    command = "#{args.join(':')}\r"
    send(command, **options)
  end
end
