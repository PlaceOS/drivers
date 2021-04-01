require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Sony::Displays::Bravia < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = "\x2A\x53" # *S
  HASH      = "################"
  ERROR     = 70
  msg_length = 21

  # INPUTS = {
  #   "Tv"     => "00000",
  #   "Hdmi"   => "10000",
  #   "Mirror" => "50000",
  #   "Vga"    => "60000",
  # }
  # INPUT_LOOKUP = INPUTS.invert

  enum Inputs
    Tv
    Tv1
    Tv2
    Tv3
    Hdmi
    Hdmi1
    Hdmi2
    Hdmi3
    Mirror
    Mirror1
    Mirror2
    Mirror3
    Vga
    Vga1
    Vga2
    Vga3
  end

  INPUTS = {
    Inputs::Tv      => "Tv",
    Inputs::Tv1     => "Tv1",
    Inputs::Tv2     => "Tv2",
    Inputs::Tv3     => "Tv3",
    Inputs::Hdmi    => "Hdmi",
    Inputs::Hdmi1   => "Hdmi1",
    Inputs::Hdmi2   => "Hdmi2",
    Inputs::Hdmi3   => "Hdmi3",
    Inputs::Mirror  => "Mirror",
    Inputs::Mirror1 => "Mirror1",
    Inputs::Mirror2 => "Mirror2",
    Inputs::Mirror3 => "Mirror3",
    Inputs::Vga     => "Vga",
    Inputs::Vga1    => "Vga1",
    Inputs::Vga2    => "Vga2",
    Inputs::Vga3    => "Vga3",
  }
  INPUT_LOOKUP = INPUTS.invert

  INPUTS_CONVERT = {
    "Tv"     => "0000",
    "Hdmi"   => "1000",
    "Mirror" => "5000",
    "Vga"    => "6000",
  }

  CONVERT_LOOKUP = INPUTS_CONVERT.invert

  include Interface::InputSelection(Inputs)

  def switch_to(input : Inputs)
    parsed_input = input.to_s.scan(/[^0-9]+|\d+/)
    index = parsed_input.size < 2 ? "1" : parsed_input[1][0]
    input_joined = INPUTS_CONVERT[parsed_input[0][0]] + index.rjust(5, '0')
    request(:input, input_joined)
    self[:input] = "#{input}"
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
    # request(:power, state ? 1 : 0)
    request(:power, state)
    logger.debug { "Sony display requested power #{state ? "on" : "off"}" }
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
    # val = state ? 1 : 0
    request(:mute, state)
    mute?
  end

  def unmute
    mute false
  end

  def mute?
    query(:mute, priority: 0)
  end

  def mute_audio(state : Bool = true)
    # val = state ? 1 : 0
    request(:audio_mute, state)
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
    if self[:power]?
      input?
      mute?
      audio_mute?
      volume?
    end
  end

  def received(data, task, **command2)
    type = BINARY_TYPE[data[2]]
    parsed_data = convert_binary(data[3..6])
    cmd = RESPONSES[parsed_data]
    param = data[7..-1]

    return task.try(&.abort("error")) if param.first? == ERROR

    case TYPE_RESPONSE[type]
    when :answer
      update_status cmd, param
      task.try &.success
    when :notify
      update_status cmd, param
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
    parameter = parameter ? 1 : 0 if parameter.is_a?(Bool)
    param = parameter.to_s.rjust(16, '0')
    do_send(:control, cmd, param, **options)
  end

  protected def query(state, **options)
    cmd = COMMANDS[state]
    do_send(:enquiry, cmd, HASH, **options)
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
      input_num = convert_binary(param[7..10])
      index_num = convert_binary(param[11..-1]).to_i
      if index_num == 1
        self[:input] = CONVERT_LOOKUP[input_num]
      else
        self[:input] = "#{CONVERT_LOOKUP[input_num]}#{index_num}"
      end
    end
  end
end
