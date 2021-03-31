require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Sony::Displays::Bravia < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = "\x2A\x53" # *S
  msg_length = 21

  enum Inputs
    Tv
    Hdmi
    Mirror
    Vga
  end

  # include Interface::InputSelection(Inputs)

  INPUTS = {
    Inputs::Tv     => "00000",
    Inputs::Hdmi   => "10000",
    Inputs::Mirror => "50000",
    Inputs::Vga    => "60000",
  }
  INPUT_LOOKUP = INPUTS.invert

  MATCH = {
    "tv"     => Inputs::Tv,
    "hdmi"   => Inputs::Hdmi,
    "mirror" => Inputs::Mirror,
    "vga"    => Inputs::Vga,
  }

  def switch_to(input : String)
    input_type = input.to_s.scan(/[^0-9]+|\d+/)
    index = input_type.size < 2 ? "1" : input_type[1][0]
    # raise ArgumentError, "unknown input #{input.to_s}" unless INPUTS.has_key?(input)
    value = INPUTS[MATCH[input_type[0][0]]]
    request(:input, "#{value}#{index.rjust(4, '0')}")
    self[:input] = "#{value}#{index}" # for a responsive UI
    input?
  end

  def input?
    query(:input, priority: 0)
  end

  # Discovery Information
  tcp_port 20060
  descriptive_name "Sony Bravia LCD Display"
  generic_name :Display

  def on_load
    self[:volume_min] = 0
    self[:volume_max] = 100
  end

  def connected
    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    if state
      request(:power, 1)
      logger.debug { "-- sony display requested to power on" }
    else
      request(:power, 0)
      logger.debug { "-- sony display requested to power off" }
    end
    power?
  end

  def power?
    query(:power)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    val = state ? 1 : 0
    request(:mute, val)
    mute?
  end

  def unmute
    mute false
  end

  def mute?
    query(:mute, priority: 0)
  end

  def mute_audio(state : Bool = true)
    val = state ? 1 : 0
    request(:audio_mute, val)
    audio_mute?
  end

  def unmute_audio
    mute_audio false
  end

  def audio_mute?
    query(:audio_mute, priority: 0)
  end

  def volume(level : Int32)
    request(:volume, level.to_i)
    volume?
  end

  def volume?
    query(:volume, priority: 0)
  end

  def do_poll
    # while power?
    if self[:power]?
      input?
      mute?
      audio_mute?
      volume?
    end
    # end
  end

  def received(data, task, **command2)
    # logger.debug { "Sony sent: #{data}" }
    type = BINARY_TYPE[data[2]]
    parsed_data = convert_binary(data[3..6])
    cmd = RESPONSES[parsed_data]
    param = data[7..-1]

    return task.try(&.abort("error")) if param[0] == 70

    case TYPE_RESPONSE[type]
    when :answer
      update_status cmd, param
      task.try &.success
    when :notify
      update_status cmd, param
      :ignore
    else
      logger.debug { "Unhandled device response" }
      task.try &.abort("Unhandled device response")
    end
  end

  COMMANDS = {
    ir_code:           "IRCC",
    power:             "POWR",
    volume:            "VOLU",
    audio_mute:        "AMUT",
    mute:              "PMUT",
    channel:           "CHNN",
    tv_input:          "ISRC",
    input:             "INPT",
    toggle_mute:       "TPMU",
    pip:               "PIPI",
    toggle_pip:        "TPIP",
    position_pip:      "TPPP",
    broadcast_address: "BADR",
    mac_address:       "MADR",
  }
  RESPONSES = COMMANDS.to_h.invert

  TYPES = {
    control: "\x43",
    enquiry: "\x45",
    answer:  "\x41",
    notify:  "\x4E",
  }

  BINARY_TYPE = {
    65 => "A",
    69 => "E",
    67 => "C",
    78 => "N",
  }

  TYPE_RESPONSE = TYPES.to_h.invert

  protected def convert_binary(data)
    data.map { |x| x.chr }.join
  end

  protected def request(command, parameter, **options)
    cmd = COMMANDS[command]
    param = parameter.to_s.rjust(16, '0')
    do_send(:control, cmd, param, **options)
  end

  protected def query(state, **options)
    cmd = COMMANDS[state]
    param = "#" * 16
    options[:name] = "#{state}_query"
    do_send(:enquiry, cmd, param, **options)
  end

  protected def do_send(type, command, parameter, **options)
    cmd_type = TYPES[type]
    cmd = "#{INDICATOR}#{cmd_type}#{command}#{parameter}\n"
    send(cmd, **options)
  end

  protected def update_status(cmd, param)
    parsed_data = convert_binary(param)
    case cmd
    when :power, :mute, :audio_mute, :pip
      self[cmd] = parsed_data.to_i == 1
    when :volume
      self[:volume] = parsed_data.to_i
    when :mac_address
      self[:mac_address] = parsed_data.split('#')[0]
    when :input
      input_num = convert_binary(param[7..11])
      index_num = convert_binary(param[12..-1]).to_i
      if index_num == 1
        self[:input] = INPUT_LOOKUP[input_num]
      else
        self[:input] = "#{INPUT_LOOKUP[input_num]}#{index_num}"
      end
    end
  end
end
