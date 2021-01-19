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

  def switch_video(input : String | Int32, output : Array(String))
    do_send(CMDS["switch_video"], build_switch_data({input => output}))
  end

  def switch_audio(input : String | Int32, output : Array(String))
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
  private def route(map : Hash(String | Int32, Array(String)), type : RouteType = RouteType::AudioVideo)
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

  private def build_switch_data(map : Hash(String | Int32, Array(String)))
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
