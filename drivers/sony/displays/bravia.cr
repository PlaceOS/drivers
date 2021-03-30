require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Sony::Displays::Bravia < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = "\x2A\x53"
  msg_length = 21

  enum Inputs
    Tv
    Hdmi
    Mirror
    Vga
  end

  include Interface::InputSelection(Inputs)

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
    index = input_type.size < 1 ? "1" : input_type[1][0]
    # raise ArgumentError, "unknown input #{input.to_s}" unless INPUTS.has_key?(input)
    value = INPUTS[MATCH[input_type[0][0]]]
    request(:input, "#{value}#{index.rjust(4, '0')}")
    logger.debug { "requested to switch to: #{input}" }
    self[:input] = input # for a responsive UI
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
    # (**options, &block)
    # options[:emit] = block?
    # options[:priority] ||= 0
    # query(:power, options)
    query(:power).get
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    val = state ? 1 : 0
    request(:mute, val)
    logger.debug { "requested to mute #{state}" }
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
    logger.debug { "requested to mute audio #{state}" }
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
    input?
    mute?
    audio_mute?
    volume?
    # power? unless
  end

  def received(data, resolve, **command)
    logger.debug { "Sony sent: #{data}" }
    type = TYPE_RESPONSE[data[0]]
    cmd = RESPONSES[data[1..4]]
    param = data[5..-1]

    return :abort if param[0] == 'F'

    case type
    when :answer
      # if command && TYPE_RESPONSE[command[:data]] == :enquiry
      #   update_status cmd, param
      # end
      :success
    when :notify
      # update_status cmd, param
      :ignore
    else
      logger.debug { "Unhandled device response" }
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
  TYPE_RESPONSE = TYPES.to_h.invert

  protected def request(command, parameter, **options)
    cmd = COMMANDS[command]
    param = parameter.to_s.rjust(16, '0')
    do_send(:control, cmd, param, **options)
  end

  protected def query(state, **options)
    cmd = COMMANDS[state]
    param = "#" * 16
    do_send(:enquiry, cmd, param)
  end

  protected def do_send(type, command, parameter, **options)
    cmd_type = TYPES[type]
    cmd = "#{INDICATOR}#{cmd_type}#{command}#{parameter}\n"
    send(cmd, **options)
  end

  # protected def update_status(cmd, param)
  #   case cmd
  #   when :power, :mute, :audio_mute, :pip
  #     self[cmd] = param.to_i == 1
  #   when :volume
  #     self[:volume] = param.to_i
  #   when :mac_address
  #     self[:mac_address] = param.split('#')[0]
  #   when :input
  #     input_num = param[7..11]
  #     index_num = param[12..-1].to_i
  #     self[:input] = if index_num == 1
  #                      INPUT_LOOKUP[input_num]
  #                    else
  #                      :"#{INPUT_LOOKUP[input_num]}#{index_num}"
  #                    end
  #   end
  # end
end
