require "placeos-driver/interface/muteable"

# Documentation: https://aca.im/driver_docs/Kramer/protocol_3000_2.10_user.pdf

class Kramer::Switcher::Protocol3000 < PlaceOS::Driver
  include Interface::Muteable

  # Discovery Information
  tcp_port 23
  descriptive_name "Kramer Protocol 3000 Switcher"
  generic_name :Switcher

  @device_id : String? = nil
  @destination : String? = nil
  @login_level : String? = nil
  @password : String? = nil

  DELIMITER = "\x0D\x0A"

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
    on_update
  end

  def on_update
    @device_id = setting?(String, :kramer_id)
    @destination = "#{@device_id}@" if @device_id
    @login_level = setting?(String, :kramer_login)
    @password = setting?(String, :kramer_password) if @login_level

    state
  end

  def connected
    state

    schedule.every(1.minute) do
      logger.debug { "-- Kramer Maintaining Connection" }
      do_send("MODEL?", priority: 0) # Low priority poll to maintain connection
    end
  end

  def disconnected
    schedule.clear
  end

  # Get current state of the switcher
  private def state
    protocol_handshake
    login
    get_machine_info
  end

  def switch_video(input : String, output : Array(String))
    do_send(CMDS["switch_video"], build_switch_data({input => output}))
  end

  def switch_audio(input : String, output : Array(String))
    do_send(CMDS["switch_video"], build_switch_data({input => output}))
  end

  enum RouteType
    Video = 1
    Audio = 2
    USB = 3
    AudioVideo = 12
    VideoUSB = 13
    AudioVideoUSB = 123
  end
  def route(map : Hash(String, Array(String)), type : RouteType = RouteType::AudioVideo)
    map.each do |input, outputs|
      outputs.each do |output|
        do_send(CMDS["route"], type.value, output, input)
      end
    end
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    mute_video(index, state) if layer.video? || layer.audio_video?
    mute_audio(index, state) if layer.audio? || layer.audio_video?
  end

  def mute_video(index : Int32 | String = 0, state : Bool = true)
    do_send(CMDS["video_mute"], index, state ? 1 : 0)
  end

  def mute_audio(index : Int32 | String = 0, state : Bool = true)
    do_send(CMDS["audio_mute"], index, state ? 1 : 0)
  end

  def help
    do_send(CMDS["help"])
  end

  def model
    do_send(CMDS["model"])
  end

  def received(data, task)
    data = String.new(data[0..-3]) # Remove delimiter "\x0D\x0A"
    logger.debug { "Kramer sent #{data}" }

    # Extract and check the machine number if we've defined it
    components = data.split('@')
    return if components.size > 1 && @device_id && components[0] != @device_id

    data = components[-1].strip
    components = data.split(/\s+|,/)

    pp "Got here"

    cmd = components[0]
    args = components[1..-1]
    args.pop if args[-1] == "OK"

    pp "Got here2"
    pp "Kramer cmd: #{cmd}, args: #{args}"
    logger.debug { "Kramer cmd: #{cmd}, args: #{args}" }

    if cmd == "OK"
      return task.try &.success
    elsif cmd[0..2] == "ERR" || args[0][0..2] == "ERR"
      if cmd[0..2] == "ERR"
        error = cmd[3..-1]
        errfor = nil
      else
        error = args[0][3..-1]
        errfor = " on #{cmd}"
      end
      self[:last_error] = error
      return task.try &.abort("Kramer command error #{error}#{errfor}")
    end

    case c = CMDS[cmd]
    when "info"
        self[:video_inputs] = args[1].to_i
        self[:video_outputs] = args[3].to_i
    when "route"
      # response looks like ~01@ROUTE 12,1,4 OK
      layer = args[0].to_i
      dest = args[1].to_i
      src = args[2].to_i
      self["#{RouteType.from_value(layer)}#{dest}"] = src
    when "switch", "switch_audio", "switch_video"
      # return string like "in>out,in>out,in>out OK"
      case c
      when "switch_audio" then type = "audio"
      when "switch_video" then type = "video"
      else type = "av" end

      args.each do |map|
        inout = map.split('>')
        self["#{type}#{inout[1]}"] = inout[0].to_i
      end
    when "audio_mute"
      # Response looks like: ~01@VMUTE 1,0 OK
      output = args[0]
      mute = args[1]
      self["audio#{output}_muted"] = mute[0] == '1'
    when "video_mute"
      output = args[0]
      mute = args[1]
      self["video#{output}_muted"] = mute[0] == '1'
    end

    task.try &.success
  end

  CMDS = {
    "info" => "INFO-IO?",
    "login" => "LOGIN",
    "route" => "ROUTE",
    "switch" => "AV",
    "switch_audio" => "AUD",
    "switch_video" => "VID",
    "audio_mute" => "MUTE",
    "video_mute" => "VMUTE",
    "help" => "HELP",
    "model" => "MODEL?"
  }
  CMDS.merge!(CMDS.invert)

  def build_switch_data(map : Hash(String, Array(String)))
    data = String.build do |str|
      map.each do |input, outputs|
        str << outputs.join { |output| "#{input}>#{output}," }
      end
    end
    data[0..-2] # Remove the comma at the end
  end

  private def protocol_handshake
    do_send("", priority: 99)
  end

  private def login
    if @login_level && (pass = @password)
      do_send(CMDS["login"], pass, priority: 99)
    end
  end

  def get_machine_info
    do_send(CMDS["info"], priority: 99)
  end

  private def do_send(command, *args, **options)
    cmd = args.empty? ? "##{@destination}#{command}\r" : "##{@destination}#{command} #{args.join(',')}\r"

    logger.debug { "Kramer sending: #{cmd}" }
    send(cmd, **options)
  end
end
