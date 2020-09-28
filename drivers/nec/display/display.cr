module Nec; end
module Nec::Display; end

require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Nec::Display::All < PlaceOS::Driver
  include Interface::Powerable
  include Interface::AudioMuteable

  enum Input
    Vga         = 1
    Rgbhv       = 2
    Dvi         = 3
    HdmiSet     = 4
    Video1      = 5
    Video2      = 6
    Svideo      = 7
    Tuner       = 9
    Tv          = 10
    Dvd1        = 12
    Option      = 13
    Dvd2        = 14
    DisplayPort = 15
    Hdmi        = 17
    Hdmi2       = 18
    Hdmi3       = 130
    Usb         = 135

    def to_s : String
      Nec::Display::All.format_value(self.value)
    end
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 7142
  descriptive_name "NEC Display"
  generic_name :Display

  default_settings({
    volume_min: 0,
    volume_max: 100
  })

  @volume_min : Int32 = 0
  @volume_max : Int32 = 100

  @target_input : Input? = nil
  @target_audio : Audio? = nil
  @input_double_check : PlaceOS::Driver::Proxy::Scheduler? = nil

  DELIMITER = 0x0D_u8

  def on_load
    # Communication settings
    queue.delay = 120.milliseconds
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
    on_update
  end

  def on_update
    @volume_min = setting(Int32, :volume_min)
    @volume_max = setting(Int32, :volume_max)
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
    return if self[:power]?.try &.as_bool? == state
    data = "C203D6"

    if state
      data += "0001" # 0001 = Power On
      logger.debug { "-- NEC LCD, requested to power on" }
      do_send(MsgType::Command, data, name: "power", delay: 5.seconds)

      mute_status(20)
      volume_status(20)
    else
      data += "0004" # 0004 = Power Off
      logger.debug { "-- NEC LCD, requested to power off" }
      do_send(MsgType::Command, data, name: "power", delay: 10.seconds, timeout: 10.seconds)

      self[:power] = false
    end
  end

  def power?(**options)
    do_send(MsgType::Command, Command::PowerQuery, **options, name: "power?")
  end

  def switch_to(input : Input)
    @target_input = input
    @target_audio = nil

    data = Command::VideoInput.to_s + input.to_s

    logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
    do_send(MsgType::SetParameter, data, name: "input", delay: 6.seconds)
    video_input
  end

  enum Audio
    Audio1      = 1
    Audio2      = 2
    Audio3      = 3
    Hdmi        = 4
    Tv          = 6
    DisplayPort = 7

    def to_s : String
      Nec::Display::All.format_value(self.value)
    end
  end

  def switch_audio(input : Audio)
    @target_audio = input

    data = Command::AudioInput.to_s + input.to_s

    logger.debug { "-- NEC LCD, requested to switch audio to: #{input}" }
    do_send(MsgType::SetParameter, data, name: "audio")
    mute_status(20) # higher status than polling commands - lower than input switching
    volume_status(20)
  end

  def auto_adjust
    data = Command::AutoSetup.to_s + "0001"
    # TODO: find out if there is an equivalent for delay_on_receive
    do_send(MsgType::SetParameter, data)#, delay_on_receive: 4.seconds)
  end

  def brightness(val : Int32)
    data = Command::BrightnessStatus.to_s + self.class.format_value(val.clamp(0, 100))

    do_send(MsgType::SetParameter, data, name: "brightness")
    do_send(MsgType::Command, "0C", name: "brightness_save") # Save the settings
  end

  def contrast(val : Int32)
    data = Command::ContrastStatus.to_s + self.class.format_value(val.clamp(0, 100))

    do_send(MsgType::SetParameter, data, name: "contrast")
    do_send(MsgType::Command, "0C", name: "contrast_save") # Save the settings
  end

  def volume(val : Int32)
    data = Command::VolumeStatus.to_s + self.class.format_value(val.clamp(0, 100))

    do_send(MsgType::SetParameter, data, name: "volume_status")
    do_send(MsgType::Command, "0C", name: "volume_save") # Save the settings
    self[:audio_mute] = false # audio is unmuted when the volume is set
  end

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    data = Command::MuteStatus.to_s + (state ? "0001" : "0000")

    logger.debug { "requested to update mute to #{state}" }
    do_send(MsgType::SetParameter, data)
  end

  def unmute_audio
    mute_audio(false)
  end

  # LCD Response code
  def received(data, task)
    ascii_string = String.new(data)
    # Check for valid response
    if !check_checksum(data)
      return task.try &.retry("-- NEC LCD, invalid response was: #{ascii_string}")
    end

    logger.debug { "NEC LCD responded with ascii_string #{ascii_string}" }

    command = MsgType.from_value(data[4])

    case command # Check the MsgType (B, D or F)
    when .command_reply?
      # Power on and off
      if ascii_string[10..15] == "C203D6" # Means power comamnd
        # 8..9 == "00" means no error
        if ascii_string[8..9] == "00"
          self[:power] = true
        else
          return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{ascii_string}")
        end
      elsif ascii_string[12..13] == "D6" # Power status response
        # 10..11 == "00" means no error
        if ascii_string[10..11] == "00"
          if ascii_string[23] == '1' # On == 1, Off == 4
            self[:power] = true
          else
            self[:power] = false
          end
        else
          return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{ascii_string}")
        end
      end
    when .get_parameter_reply?, .set_parameter_reply?
      if ascii_string[8..9] == "00"
        parse_response(ascii_string)
      elsif ascii_string[8..9] == "BE"    # Wait response
        return task.try &.retry("-- NEC LCD, response was a wait command")
      else
        return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{ascii_string}")
      end
    end

    task.try &.success
  end

  def do_poll
    power?(priority: 0)
    logger.debug { "Polling, power = #{self[:power]}" }

    # TODO: not sure why but this seems to never run even even if self[:power] == true
    # if self[:power]?
    if self[:power]?.try &.as_bool?
      mute_status
      volume_status
      video_input
      audio_input
    end
  end

  private def parse_response(data : String)
    # 14..15 == type (we don't care)
    max = data[16..19].to_i(16)
    value = data[20..23].to_i(16)

    case Command.from_value(data[10..13].to_i(16))
    when .video_input?
      input = Input.from_value(value)
      self[:input] = input
      target_input = @target_input ||= input
      if target_input && self[:input] != self[:target_input]
        switch_to(target_input)
      end
    when .audio_input?
      self[:audio] = Audio.from_value(value)
      target_audio = @target_audio
      if target_audio && self[:audio] != self[:target_audio]
        switch_audio(target_audio)
      end
    when .volume_status?
      self[:volume_max] = max
      unless self[:audio_mute]
        self[:volume] = value
      end
    when .brightness_status?
      self[:brightness_max] = max
      self[:brightness] = value
    when .contrast_status?
      self[:contrast_max] = max
      self[:contrast] = value
    when .mute_status?
      self[:audio_mute] = value == 1
      if(value == 1)
        self[:volume] = 0
      else
        volume_status(60) # high priority
      end
    when .auto_setup?
      # auto_setup
      # nothing needed to do here (we are delaying the next command by 4 seconds)
    else
      logger.info { "-- NEC LCD, unknown response: #{data[10..13]}" }
      logger.info { "-- NEC LCD, full response was: #{data}" }
    end
  end

  # Types of messages sent to and from the LCD
  enum MsgType
    Command           = 0x41 # 'A'
    CommandReply      = 0x42 # 'B'
    GetParameter      = 0x43 # 'C'
    GetParameterReply = 0x44 # 'D'
    SetParameter      = 0x45 # 'E'
    SetParameterReply = 0x46 # 'F'
  end

  enum Command
    VideoInput       = 0x0060
    AudioInput       = 0x022E
    VolumeStatus     = 0x0062
    MuteStatus       = 0x008D
    PowerOnDelay     = 0x02D8
    ContrastStatus   = 0x0012
    BrightnessStatus = 0x0010
    AutoSetup        = 0x001E
    PowerQuery       = 0x01D6

    def to_s : String
      Nec::Display::All.format_value(self.value)
    end
  end

  def self.format_value(value : Int, length : Int = 4) : String
    value.to_s(16, true).rjust(length, '0')
  end

  {% for name in Command.constants %}
    @[Security(Level::Administrator)]
    def {{name.id.underscore}}(priority : Int32 = 0)
      do_send(MsgType::GetParameter, Command::{{name.id}}, priority: priority, name: {{name.id.underscore.stringify}})
    end
  {% end %}

  private def check_checksum(data : Bytes)
    checksum = 0x00_u8
    # Loop through the second to the third last element
    if data.size >= 2
      data[1..-3].each do |b|
        checksum = checksum ^ b
      end
      # Check the checksum equals the second last element
      logger.debug { "Error: checksum should be #{checksum.to_s(16)}" } unless checksum == data[-2]
      checksum == data[-2]
    else
      true
    end
  end

  # Builds the command and creates the checksum
  # data can be an ascii encoded string
  private def do_send(type : MsgType, data : Command | String, **options)
    data = data.to_s if data.is_a?(Command)
    data = data.bytes
    bytes = Bytes.new(data.size + 11)

    # Header
    bytes[0] = 0x01 # SOH
    bytes[1] = 0x30 # '0'
    bytes[2] = 0x2A # '*'
    bytes[3] = 0x30 # '0'
    bytes[4] = type.value.to_u8
    message_length = self.class.format_value(data.size + 2, 2).bytes
    bytes[5] = message_length[0]
    bytes[6] = message_length[1]

    # Message
    bytes[7] = 0x02 # Start of messsage
    data.each_with_index(8) { |b, i| bytes[i] = b }
    bytes[8 + data.size] = 0x03 # End of message

    # Checksum
    checksum = 0x00_u8
    bytes[1..8 + data.size].each do |b|
      checksum = checksum ^ b
    end
    bytes[-2] = checksum

    bytes[-1] = DELIMITER

    send(bytes, **options)
  end
end
