# Documentation: https://aca.im/driver_docs/Kramer/protocol_3000_2.10_user.pdf

class Kramer::Switcher::Protocol3000 < PlaceOS::Driver
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
  # def route(map, type = :audio_video)
  #   map.each do |input, outputs|
  #     input = input.to_s if input.is_a?(Symbol)
  #     input = input.to_i if input.is_a?(String)

  #     outputs.each do |output|
  #       do_send(CMDS[:route], ROUTE_TYPES[type], output, input)
  #     end
  #   end
  # end

  private def do_send(command, *args, **options)
    cmd = args.empty? ? "##{@destination}#{command}\r" : "##{@destination}#{command} #{args.join(',')}\r"

    logger.debug { "Kramer sending: #{cmd}" }
    send(cmd, **options)
  end

  def received(data, task)
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
end
