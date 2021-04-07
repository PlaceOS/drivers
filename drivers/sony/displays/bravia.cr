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
    Tv1
    Tv2
    Tv3
    Hdmi1
    Hdmi2
    Hdmi3
    Mirror1
    Mirror2
    Mirror3
    Vga1
    Vga2
    Vga3

    def index : Int32
      to_s.gsub(/[^0-9]/, "").to_i
    end

    def type_hint : String
      case self
      in Tv1, Tv2, Tv3
        "0000"
      in Hdmi1, Hdmi2, Hdmi3
        "1000"
      in Mirror1, Mirror2, Mirror3
        "5000"
      in Vga1, Vga2, Vga3
        "6000"
      end
    end

    def self.from_message?(type_hint, index)
      type = case type_hint
             when '0' then "Tv"
             when '1' then "Hdmi"
             when '5' then "Mirror"
             when '6' then "Vga"
             end

      "#{type}#{index}" if type
    end

    def to_message : String
      "#{type_hint}#{(index).to_s.rjust(5, '0')}"
    end
  end

  include Interface::InputSelection(Inputs)

  def switch_to(input : Inputs)
    logger.debug { "switching input to #{input}" }
    request(Command::Input, input.to_message)
    self[:input] = input.to_s
    input?
  end

  def input?
    query(Command::Input, priority: 0)
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
    request(Command::Power, state)
    logger.debug { "Sony display requested power #{state ? "on" : "off"}" }
    power?
  end

  def power?
    query(Command::Power)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    request(Command::Mute, state)
    mute?
  end

  def unmute
    mute false
  end

  def mute?
    query(Command::Mute, priority: 0)
  end

  def mute_audio(state : Bool = true)
    request(Command::AudioMute, state)
    audio_mute?
  end

  def unmute_audio
    mute_audio false
  end

  def audio_mute?
    query(Command::AudioMute, priority: 0)
  end

  def volume(level : Int32)
    request(Command::Volume, level.to_i)
    volume?
  end

  def volume?
    query(Command::Volume, priority: 0)
  end

  def do_poll
    if self[:power]?
      input?
      mute?
      audio_mute?
      volume?
    end
  end

  enum MessageType : UInt8
    Answer  = 0x41
    Control = 0x43
    Enquiry = 0x45
    Notify  = 0x4e

    def control_character
      value.chr
    end
  end

  def received(data, task)
    parsed_data = convert_binary(data[3..6])
    cmd = Command.from_response?(parsed_data)
    return task.try(&.abort("unrecognised command: #{parsed_data}")) if cmd.nil?
    param = data[7..-1]
    return task.try(&.abort("error")) if param.first? == ERROR
    case MessageType.from_value?(data[2])
    when MessageType::Answer
      update_status cmd, param
      task.try &.success
    when MessageType::Notify
      update_status cmd, param
    else
      logger.debug { "Unhandled device response: #{data[2].chr rescue data[2]}" }
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

  {% begin %}
  enum Command
    {% begin %}
      {% for command in COMMANDS.keys %}
        {{ command.camelcase.id }}
      {% end %}
    {% end %}

    def function
      {% begin %}
      case self
      {% for kv in COMMANDS.to_a %}
        {% command, value = kv[0], kv[1] %}
          in {{ command.camelcase }} then {{ value }}
      {% end %}
      end
      {% end %}
    end

    def self.from_response?(message)
      {% begin %}
      case message
        {% for kv in COMMANDS.to_a %}
          {% command, value = kv[0], kv[1] %}
          when {{ value }} then {{ command.camelcase.id }}
        {% end %}
      end
      {% end %}
    end
  end
  {% end %}

  protected def convert_binary(data)
    String.new(slice: data)
  end

  protected def request(command, parameter, **options)
    cmd = command.function
    parameter = parameter ? 1 : 0 if parameter.is_a?(Bool)
    param = parameter.to_s.rjust(16, '0')
    do_send(MessageType::Control, cmd, param, **options)
  end

  protected def query(state, **options)
    cmd = state.function
    do_send(MessageType::Enquiry, cmd, HASH, **options)
  end

  protected def do_send(type, command, parameter, **options)
    cmd = "#{INDICATOR}#{type.control_character}#{command}#{parameter}\n"
    send(cmd, **options)
  end

  protected def update_status(cmd : Command, param)
    parsed_data = convert_binary(param)
    case cmd
    when .power?
      self[:power] = parsed_data.to_i == 1
    when .mute?
      self[:mute] = parsed_data.to_i == 1
    when .audio_mute?
      self[:audio_mute] = parsed_data.to_i == 1
    when .pip?
      self[:pip] = parsed_data.to_i == 1
    when .volume?
      self[:volume] = parsed_data.to_i
    when .mac_address?
      self[:mac_address] = parsed_data.split('#')[0]
    when .input?
      self[:input] = Inputs.from_message?(parsed_data[7], parsed_data[15])
    end
  end
end
