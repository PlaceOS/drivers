require "driver/interface/powerable"
require "driver/interface/muteable"
require "driver/interface/switchable"

module Nec; end
module Nec::Display; end

# :title:All NEC Control Module
#
# Controls all LCD displays as of 1/07/2011
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# power
# warming
#
# volume
# volume_min == 0
# volume_max
#
# brightness
# brightness_min == 0
# brightness_max
#
# contrast
# contrast_min = 0
# contrast_max
#
# audio_mute
#
# input (video input)
# audio (audio input)

class Nec::Display::All < PlaceOS::Driver
  include Interface::Powerable
  include Interface::AudioMuteable

  enum Inputs
    Vga          = 1
    Rgbhv        = 2
    Dvi          = 3
    Hdmi_set     = 4
    Video1       = 5
    Video2       = 6
    Svideo       = 7
    Tuner        = 9
    Tv           = 10
    Dvd1         = 12
    Option       = 13
    Dvd2         = 14
    Display_port = 15
    Hdmi         = 17
    Hdmi2        = 18
    Hdmi3        = 130
    Usb          = 135
  end
  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  # Discovery Information
  tcp_port 7142
  descriptive_name "NEC LCD Display"
  generic_name :Display

  default_settings({
    volume_min: 0,
    volume_max: 100
  })

  @volume_min : Int32 = 0
  @volume_max : Int32 = 100

  # 0x0D (<CR> carriage return \r)
  DELIMITER = 0x0D_u8

  @target_input : Input? = nil
  @target_audio : Audio? = nil
  @input_double_check : PlaceOS::Driver::Proxy::Scheduler? = nil

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
    # Disconnected may be called without calling connected
    # Hence the check if timer is nil here
    schedule.clear
  end

  def power(state : Bool)
    data = "C203D6"
    current = self[:power]?

    if current
      data += "0004" # 0004 = Power Off
      do_send("command", data, name: "power", delay: 10.seconds, timeout: 10.seconds)

      self[:power] = false
      logger.debug { "-- NEC LCD, requested to power off" }
    else
      data += "0001" # 0001 = Power Off
      do_send("command", data, name: "power", delay: 5.seconds)
      self[:warming] = true
      self[:power] = true
      logger.debug { "-- NEC LCD, requested to power on" }

      power_on_delay
      mute_status(20)
      volume_status(20)
    end
  end

  def power?(**options)
    # options[:emit] = block if block_given?
    do_send("command", "01D6", **options)
  end

  def switch_to(input : Input)
    @target_input = input
    @target_audio = nil

    data = OPERATIONS[:video_input]
    data += input.value.to_s(16).upcase.rjust(4, '0')

    do_send("set parameter", data, name: "input", delay: 6.seconds)
    video_input

    # Double check the input again!
    # @input_double_check.cancel if @input_double_check
    # @input_double_check = schedule.in(4.seconds) do
    #   @input_double_check = nil
    #   video_input
    # end
    # TODO: check if the below is equivalent to what's above
    @input_double_check.try &.terminate
    schedule.in(4.seconds) do
      @input_double_check = nil
      video_input.as(PlaceOS::Driver::Transport)
    end

    logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
  end

  enum Audio
    Audio1        = 1
    Audio2        = 2
    Audio3        = 3
    Hdmi          = 4
    Tv            = 6
    Display_port  = 7
  end

  def switch_audio(input : Audio)
    @target_audio = input

    data = OPERATIONS[:audio_input]
    data += input.value.to_s(16).upcase.rjust(4, '0')

    do_send("set parameter", data, name: "audio")
    mute_status(20) # higher status than polling commands - lower than input switching
    volume_status(20)

    logger.debug { "-- NEC LCD, requested to switch audio to: #{input}" }
  end

  def auto_adjust
    data = OPERATIONS[:audio_setup]
    data += "0001"
    # TODO: find out if there is an equivalent for delay_on_receive
    do_send("set parameter", data)#, delay_on_receive: 4.seconds)
  end

  def brightness(val : Int32)
    data = OPERATIONS[:brightness_status]
    data += val.clamp(0, 100).to_s(16).upcase.rjust(4, '0')

    do_send("set_parameter", data, name: "brightness")
    do_send("command", "0C", name: "brightness_save") # Save the settings
  end

  def contrast(val : Int32)
    data = OPERATIONS[:contrast_status]
    data += val.clamp(0, 100).to_s(16).upcase.rjust(4, '0')

    do_send("set_parameter", data, name: "contrast")
    do_send("command", "0C", name: "contrast_save") # Save the settings
  end

  def volume(val : Int32)
    data = OPERATIONS[:volume_status]
    data += val.clamp(0, 100).to_s(16).upcase.rjust(4, '0')

    do_send("set_parameter", data, name: "volume_status")
    do_send("command", "0C", name: "volume_save") # Save the settings
    self[:audio_mute] = false # audio is unmuted when the volume is set
  end

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    data = OPERATIONS[:mute_status]
    data += state ? "0001" : "0000"

    do_send("set_parameter", data)
    logger.debug { "requested to update mute to #{state}" }
  end

  def unmute_audio
    mute_audio(false)
  end

  # LCD Response code
  def received(data, task)
    hex = data.hexstring
    # Check for valid response
    if !check_checksum(data)
      return task.try &.retry("-- NEC LCD, invalid response was: #{hex}")
    end

    logger.debug { "NEC LCD responded #{hex}" }

    command = MSG_TYPE[data[4]]

    case command # Check the MSG_TYPE (B, D or F)
      when "command_reply"
        # Power on and off
        # 8..9 == "00" means no error
        if hex[10..15] == "c203d6" # Means power comamnd
          if hex[8..9] == "00"
            power_on_delay(99) # wait until the screen has turned on before sending commands (99 == high priority)
          else
            return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{hex}")
          end
        elsif hex[10..13] == "00d6" # Power status response
          if hex[10..11] == "00"
            if hex[23] == "1" # On == 1, Off == 4
              self[:power] = true
            else
              self[:power] = false
              self[:warming] = false
            end
          else
            return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{hex}")
          end
        end
      when "get_parameter_reply", "set_parameter_reply"
        if hex[8..9] == "00"
          parse_response(hex)
        elsif data[8..9] == "BE"    # Wait response
          return task.try &.retry("-- NEC LCD, response was a wait command")
        else
          return task.try &.abort("-- NEC LCD, command failed: #{command}\n-- NEC LCD, response was: #{hex}")
        end
    end

    task.try &.success
  end

  def do_poll
    power?(priority: 0)
    logger.debug { "Polling, power = #{self[:power]}" }

    if self[:power]?
      power_on_delay
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

    case OPERATION_CODE[data[10..13]]
      when :video_input
        input = Inputs.from_value(value)
        self[:input] = input
        target_input = @target_input ||= input
        if target_input && self[:input] != self[:target_input]
          switch_to(target_input)
        end
      when :audio_input
        self[:audio] = Audio.from_value(value)
        target_audio = @target_audio
        if target_audio && self[:audio] != self[:target_audio]
          switch_audio(target_audio)
        end
      when :volume_status
        self[:volume_max] = max
        unless self[:audio_mute]
          self[:volume] = value
        end
      when :brightness_status
        self[:brightness_max] = max
        self[:brightness] = value
      when :contrast_status
        self[:contrast_max] = max
        self[:contrast] = value
      when :mute_status
        self[:audio_mute] = value == 1
        if(value == 1)
          self[:volume] = 0
        else
          volume_status(60) # high priority
        end
      when :power_on_delay
        if value > 0
          self[:warming] = true
          schedule.in(value.seconds) do # Prevent any commands being sent until the power on delay is complete
            power_on_delay.as(PlaceOS::Driver::Transport)
          end
        else
          schedule.in(3.seconds) do # Reactive the interface once the display is online
            self[:warming] = false # allow access to the display
          end
        end
      when :auto_setup
        # auto_setup
        # nothing needed to do here (we are delaying the next command by 4 seconds)
      else
        logger.info { "-- NEC LCD, unknown response: #{data[10..13]}" }
        logger.info { "-- NEC LCD, full response was: #{data}" }
      end
  end

  # Types of messages sent to and from the LCD
  MSG_TYPE = {
    "command" => "A",
    "B" => "command_reply",
    "get_parameter" => "C",
    "D" => "get_parameter_reply",
    "set_parameter" => "E",
    "F" => "set_parameter_reply"
  }

  OPERATIONS = {
    "video_input" => "0060",
    "audio_input" => "022e",
    "volume_status" => "0062",
    "mute_status" => "008d",
    "power_on_delay" => "02d8",
    "contrast_status" => "0012",
    "brightness_status" => "0010",
    "auto_setup" => "001e"
  }
  OPERATION_CODE = OPERATIONS.merge(OPERATIONS.invert)

  {% for name in OPERATIONS.keys %}
  @[Security(Level::Administrator)]
    def {{name.id}}(priority : Int32 = 0)
      data = OPERATION_CODE[{{name}}]
      do_send(:get_parameter, data, priority: priority, name: {{name.id}})
    end
  {% end %}

  private def check_checksum(data : Bytes)
    checksum = 0x00_u8
    # Loop through the second to the second last element
    # Delimiter is removed automatically
    if data.size >= 2
      data[1..-2].each do |b|
        checksum = checksum ^ b
      end
      # Check the checksum equals the last element
      checksum == data[-1]
    else
      true
    end
  end

  # Builds the command and creates the checksum
  private def do_send(type : String, data : String = "", **options)
    command = "\x02#{data}\x03"
    command = "0*0#{MSG_TYPE[type]}#{command.size.to_s(16).upcase.rjust(2, '0')}#{command}"
    logger.info { "command is #{command}" }
    command = command.bytes

    checksum = 0x00_u8
    command.each do |b|
      checksum = checksum ^ b
    end

    bytes = Bytes.new(command.size + 3)
    bytes[0] = 0x01
    command.each_with_index(1) { |b, i| bytes[i] = b }
    bytes[-2] = checksum
    bytes[-1] = 0x0D

    send(bytes, **options)
  end
end