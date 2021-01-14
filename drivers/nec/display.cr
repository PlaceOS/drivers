require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Nec::Display < PlaceOS::Driver
  include Interface::Powerable
  include Interface::AudioMuteable

  enum Input
    Vga         =   1
    Rgbhv       =   2
    Dvi         =   3
    HdmiSet     =   4
    Video1      =   5
    Video2      =   6
    Svideo      =   7
    Tuner       =   9
    Tv          =  10
    Dvd1        =  12
    Option      =  13
    Dvd2        =  14
    DisplayPort =  15
    Hdmi        =  17
    Hdmi2       =  18
    Hdmi3       = 130
    Usb         = 135
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 7142
  descriptive_name "NEC Display"
  generic_name :Display

  DELIMITER = 0x0D_u8

  def on_load
    # Communication settings
    queue.delay = 120.milliseconds
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
  end

  def connected
    schedule.every(50.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    # Do nothing if already in desired state
    return if self[:power]? == state

    if state
      logger.debug { "-- NEC LCD, requested to power on" }
      # 1 = Power On
      data = MsgType::Command.build(Command::SetPower, 1)
      send(data, name: "power", delay: 5.seconds)
    else
      logger.debug { "-- NEC LCD, requested to power off" }
      # 4 = Power Off
      data = MsgType::Command.build(Command::SetPower, 4)
      send(data, name: "power", delay: 10.seconds, timeout: 10.seconds)
    end
  end

  def power?(**options) : Bool
    data = MsgType::Command.build(Command::PowerQuery)
    send(data, **options, name: "power?").get
    self[:power].as_bool
  end

  def switch_to(input : Input)
    logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
    data = MsgType::SetParameter.build(Command::VideoInput, input.value)
    send(data, name: "input", delay: 6.seconds)
  end

  enum Audio
    Audio1      = 1
    Audio2      = 2
    Audio3      = 3
    Hdmi        = 4
    Tv          = 6
    DisplayPort = 7
  end

  def switch_audio(input : Audio)
    logger.debug { "-- NEC LCD, requested to switch audio to: #{input}" }
    data = MsgType::SetParameter.build(Command::AudioInput, input.value)
    send(data, name: "audio")
  end

  def auto_adjust
    data = MsgType::SetParameter.build(Command::AutoSetup, 1)
    send(data, name: "auto_adjust")
  end

  def brightness(val : Int32)
    data = MsgType::SetParameter.build(Command::BrightnessStatus, val.clamp(0, 100))
    send(data, name: "brightness")
    send(MsgType::Command.build(Command::Save), name: "save", priority: 0)
  end

  def contrast(val : Int32)
    data = MsgType::SetParameter.build(Command::ContrastStatus, val.clamp(0, 100))
    send(data, name: "contrast")
    send(MsgType::Command.build(Command::Save), name: "save", priority: 0)
  end

  def volume(val : Int32)
    data = MsgType::SetParameter.build(Command::VolumeStatus, val.clamp(0, 100))
    send(data, name: "volume")
    send(MsgType::Command.build(Command::Save), name: "save", priority: 0)
  end

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    logger.debug { "requested to update mute to #{state}" }
    data = MsgType::SetParameter.build(Command::MuteStatus, state ? 1 : 0)
    send(data, name: "mute_audio")
  end

  def do_poll
    current_power = power?(priority: 0)
    logger.debug { "Polling, power = #{current_power}" }

    if current_power
      mute_status
      volume_status
      video_input
      audio_input
    end
  end

  # LCD Response code
  def received(data, task)
    ascii_string = String.new(data)
    # Check for valid response
    if !check_checksum(data)
      return task.try &.retry("-- NEC LCD, invalid response was: #{ascii_string}")
    end

    logger.debug { "NEC LCD responded with ascii_string #{ascii_string}" }

    if ascii_string[8..9] == "00"
      parse_response(ascii_string)
    elsif ascii_string[10..13] == "00D6" # Annoyingly unique case to deal with power status query
      self[:power] = ascii_string[23] == '1'
    elsif ascii_string[8..9] == "BE" # Wait response
      return task.try &.retry("-- NEC LCD, response was a wait command")
    else
      return task.try &.abort("-- NEC LCD, command failed: #{task.try(&.name)}\n-- NEC LCD, response was: #{ascii_string}")
    end

    task.try &.success
  end

  private def parse_response(data : String)
    logger.debug { "data is #{data}" }

    if data.size >= 15
      command = (
        # For most commands
        Command.from_value?(data[10..13].to_i(16)) || \
        # For Command::SetPower
        Command.from_value?(data[10..15].to_i(16))
      ).not_nil!
    else # This is a short command and is most likely Command::Save
      # This line will error if this is not Command::Save which is fine
      command = Command.from_value(data[9..10].to_i(16))
      # Don't do any processing for Command::Save
      return if command.save?
    end
    value = (command.set_power? ? data[16..19] : data[20..23]).to_i(16)

    case command
    when .video_input?
      self[:input] = Input.from_value(value)
    when .audio_input?
      self[:audio] = Audio.from_value(value)
    when .volume_status?
      self[:volume] = value
      self[:audio_mute] = value == 0
    when .brightness_status?
      self[:brightness] = value
    when .contrast_status?
      self[:contrast] = value
    when .mute_status?
      self[:audio_mute] = value == 1
      self[:volume] = 0 if value == 1
    when .auto_setup?
      # auto_setup
      # nothing needed to do here (we are delaying the next command by 4 seconds)
    when .set_power?
      self[:power] = value == 1
    else
      logger.debug { "-- NEC LCD, unknown response received: #{data}" }
    end
  end

  enum Command
    VideoInput       =   0x0060
    AudioInput       =   0x022E
    VolumeStatus     =   0x0062
    MuteStatus       =   0x008D
    PowerOnDelay     =   0x02D8
    ContrastStatus   =   0x0012
    BrightnessStatus =   0x0010
    AutoSetup        =   0x001E
    PowerQuery       =   0x01D6
    Save             =     0x0C
    SetPower         = 0xC203D6

    def to_s : String
      case self
      when .save?
        length = 2
      when .set_power?
        length = 6
      else
        length = 4
      end
      value.to_s(16, true).rjust(length, '0')
    end
  end

  {% for name in Command.constants %}
    @[Security(Level::Administrator)]
    def {{name.id.underscore}}(priority : Int32 = 0)
      send(MsgType::GetParameter.build(Command::{{name.id}}), priority: priority, name: {{name.id.underscore.stringify}})
    end
  {% end %}

  private def check_checksum(data : Bytes)
    # Loop through the second to the third last element
    checksum = data[1..-3].reduce { |a, b| a ^ b }
    # Check the checksum equals the second last element
    logger.debug { "Error: checksum should be 0x#{checksum.to_s(16)}" } unless checksum == data[-2]
    checksum == data[-2]
  end

  # Types of messages sent to and from the LCD
  enum MsgType : UInt8
    Command           = 0x41 # 'A'
    CommandReply      = 0x42 # 'B'
    GetParameter      = 0x43 # 'C'
    GetParameterReply = 0x44 # 'D'
    SetParameter      = 0x45 # 'E'
    SetParameterReply = 0x46 # 'F'

    def build(command : Nec::Display::Command, data : Int? = nil)
      command = command.to_s

      message = String.build do |str|
        str << "0*0"
        str.write_byte self.value # Type

        message_length = command.size + 2
        message_length += 4 if d = data                    # If there is data, add 4 to the message length
        str << message_length.to_s(16, true).rjust(2, '0') # Message length
        str.write_byte 0x02                                # Start of messsage
        str << command                                     # Message
        str << d.to_s(16, true).rjust(4, '0') if d         # Data if required
        str.write_byte 0x03                                # End of message
      end

      String.build do |str|
        str.write_byte 0x01                                      # SOH
        str << message                                           # Message
        str.write_byte message.each_byte.reduce { |a, b| a ^ b } # Checksum
        str.write_byte DELIMITER                                 # Delimiter
      end
    end
  end
end
