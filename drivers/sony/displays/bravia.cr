require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Sony::Displays::Bravia < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = "\x2A\x53" # *S
  HASH      = "################"
  ERROR     = 70

  # Discovery Information
  tcp_port 20060
  descriptive_name "Sony Bravia LCD Display"
  generic_name :Display

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

  def received(data, task)
    parsed_data = convert_binary(data[3..6])
    cmd = RESPONSES[parsed_data]
    param = data[7..-1]

    return task.try(&.abort("error")) if param.first? == ERROR

    case MessageType.from_value(data[2])
    when .answer?
      update_status cmd, param
      task.try &.success
    when .notify?
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

  enum MessageType : UInt8
    Answer  = 0x41
    Control = 0x43
    Enquiry = 0x45
    Notify  = 0x4e

    def control_character
      case self
      in Answer  then "A"
      in Control then "C"
      in Enquiry then "E"
      in Notify  then "N"
      end
    end
  end

  protected def convert_binary(data)
    data.join &.chr
  end

  protected def request(command, parameter, **options)
    cmd = COMMANDS[command]
    parameter = parameter ? 1 : 0 if parameter.is_a?(Bool)
    param = parameter.to_s.rjust(16, '0')
    do_send(MessageType::Control, cmd, param, **options)
  end

  protected def query(state, **options)
    cmd = COMMANDS[state]
    do_send(MessageType::Enquiry, cmd, HASH, **options)
  end

  protected def do_send(type, command, parameter, **options)
    cmd = "#{INDICATOR}#{type.control_character}#{command}#{parameter}\n"
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
