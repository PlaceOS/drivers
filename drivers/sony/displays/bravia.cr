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

  def switch_to(input : Inputs)
    input_type = input.to_s.scan(/[^0-9]+|\d+/)
    index = input_type.size < 1 ? "1" : input_type[1][0]

    # raise ArgumentError, "unknown input #{input.to_s}" unless INPUTS.has_key?(input)

    control(:input, "#{INPUTS[input]}#{index.rjust(4, '0')}")
    logger.debug { "requested to switch to: #{input.to_s}" }
    self[:input] = input # for a responsive UI
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
      poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power
    # TO DO
  end

  def power?
    # TO DO
  end

  def mute
    # TO DO
  end

  def unmute
    # TO DO
  end

  def mute?
    # TO DO
  end

  def mute_audio
    # TO DO
  end

  def unmute_audio
    # TO DO
  end

  def audio_mute?
    # TO DO
  end

  def volume
  end

  def poll
  end

  def received(data, resolve, command)
    logger.debug { "Sony sent: #{data}" }
    type = TYPE_RESPONSE[data[0]]
    cmd = RESPONSES[data[1..4]]
    param = data[5..-1]

    return :abort if param[0] == 'F'

    case type
    when :answer
      if command && TYPE_RESPONSE[command[:data]] == :enquiry
        update_status cmd, param
      end
      :success
    when :notify
      update_status cmd, param
      :ignore
    else
      logger.debug "Unhandled device response"
    end
  end

  def request(command, parameter, **options)
    cmd = COMMANDS[command]
    param = parameter.to_s.rjust(16, '0')
    do_send(:control, cmd, param, options)
  end

  def query(state, **options)
    cmd = COMMANDS[state]
    param = "#" * 16
    do_send(:enquiry, cmd, param, options)
  end

  def do_send(type, command, parameter, **options)
    cmd_type = TYPES[type]
    cmd = "#{INDICATOR}#{cmd_type}#{command}#{parameter}\n"
    send(cmd, option)
  end

  def update_status(cmd, param)
    case cmd
    when :power, :mute, :audio_mute, :pip
      self[cmd] = param.to_i == 1
    when :volume
      self[:volume] = param.to_i
    when :mac_address
      self[:mac_address] = param.split('#')[0]
    when :input
      input_num = param[7..11]
      index_num = param[12..-1].to_i
      self[:input] = if index_num == 1
                       INPUT_LOOKUP[input_num]
                     else
                       :"#{INPUT_LOOKUP[input_num]}#{index_num}"
                     end
    end
  end
end
