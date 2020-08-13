require "driver/interface/powerable"

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

  # Communication settings
  @delay_between_sends = 120
  @wait_response_timeout = 5000
  @input_double_check : PlaceOS::Driver::Proxy::Scheduler? = nil

  def on_load
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
    current = self[:power]?

    if current
      data = Bytes[0xC2, 0x03, 0xD6, 0x00, 0x04] # 0004 = Power Off
      # TODO: port over commented section in line below
      do_send("command", data)#, name: :power, delay: 10000, timeout: 10000)

      self[:power] = false
      logger.debug { "-- NEC LCD, requested to power off" }
    else
      data = Bytes[0xC2, 0x03, 0xD6, 0x00, 0x01] # 0001 = Power On
      # TODO: port over commented section in line below
      do_send("command", data)#, name: :power, delay: 5000)
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
    do_send("command", Bytes[0x01, 0xD6], **options)
  end

  # Input selection
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

  def switch_to(input : String)
    input = Inputs.parse(input)
    self[:target_input] = input
    self[:target_audio] = nil

    operation_index = OPERATION_NAMES.index(:video_input)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = input.value.to_u8

      # TODO: port over commented section in line below
      do_send("set parameter", data)#, name: :input, delay: 6000)
      video_input

      # Double check the input again!
      # @input_double_check.cancel if @input_double_check
      # TODO: check if the below is equivalent
      if input_double_check = @input_double_check
        input_double_check.clear
      end
      # TODO: figure out how to port to crystal
      # @input_double_check = schedule.in(4.seconds) do
      #   @input_double_check = nil
      #   video_input
      # end

      logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
    end
  end

  enum Audio
    Audio1        = 1
    Audio2        = 2
    Audio3        = 3
    Hdmi          = 4
    Tv            = 6
    Display_port  = 7
  end

  def switch_audio(input : String)
    input = Audio.parse(input)
    self[:target_audio] = input

    operation_index = OPERATION_NAMES.index(:audio_input)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = input.value.to_u8

      # TODO: port over commented section in line below
      do_send("set parameter", data)#, name: :audio)
      mute_status(20) # higher status than polling commands - lower than input switching
      volume_status(20)

      logger.debug { "-- NEC LCD, requested to switch audio to: #{input}" }
    end
  end

  def auto_adjust
    operation_index = OPERATION_NAMES.index(:audio_setup)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = 0x01

      # TODO: port over commented section in line below
      do_send("set parameter", data)#, delay_on_receive: 4000)
    end
  end

  def brightness(val : Int32)
    operation_index = OPERATION_NAMES.index(:brightness_status)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = val.clamp(0, 100).to_u8

      do_send("set_parameter", message)#, name: :brightness)
      do_send("command", Bytes[0x0C])#, name: :brightness_save) # Save the settings
    end
  end

  def contrast(val : Int32)
    operation_index = OPERATION_NAMES.index(:contrast_status)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = val.clamp(0, 100).to_u8
      do_send("set_parameter", message)#, name: :contrast)
      do_send("command", Bytes[0x0C])#, name: :contrast_save)    # Save the settings
    end
  end

  def volume(val : Int32)
    operation_index = OPERATION_NAMES.index(:volume_status)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 2)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = val.clamp(0, 100).to_u8
      do_send("set_parameter", message)#, name: :volume_status)
      do_send("command", Bytes[0x0C])#, name: :volume_save) # Save the settings
      self[:audio_mute] = false # audio is unmuted when the volume is set
    end
  end

  def mute_audio(state : Bool = true)
    operation_index = OPERATION_NAMES.index(:mute_status)
    if operation_index
      message = OPERATION_VALUES[operation_index]
      data = Bytes.new(message.size + 1)
      data.copy_from(message)
      data[message.size] = 0x00
      data[message.size + 1] = (state ? 0x01 : 0x00).to_u8
      do_send("set_parameter", message)
      logger.debug { "requested to update mute to #{state}" }
    end
  end
  # alias_method :mute, :mute_audio

  def unmute_audio
    mute_audio(false)
  end
  # alias_method :unmute, :unmute_audio

  # LCD Response code
  def received(data, task)
    hex = data.hexstring
    # Check for valid response
    if !check_checksum(data)
      return task.try &.retry("-- NEC LCD, invalid response was: #{hex}")
    end

    logger.debug { "NEC LCD responded #{hex}" }

    command = MsgType.from_value(data[4])

    case command # Check the MsgType (B, D or F)
      when .command_reply?
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
      when .get_parameter_reply?, .set_parameter_reply?
        if hex[8..9] == "00"
          # TODO
          # parse_response(data)
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

  private def parse_response(hex : String)
    # 14..15 == type (we don't care)
    max = data[16..19].to_i(16)
    value = data[20..23].to_i(16)

    case OPERATION_CODE[data[10..13]]
      when :video_input
        self[:input] = INPUTS[value]
        self[:target_input] = self[:input] if self[:target_input].nil?
        switch_to(self[:target_input]) unless self[:input] == self[:target_input]
      when :audio_input
        self[:audio] = AUDIO[value]
        switch_audio(self[:target_audio]) if self[:target_audio] && self[:audio] != self[:target_audio]
      when :volume_status
        self[:volume_max] = max
        if not self[:audio_mute]
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
            power_on_delay
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
        logger.info "-- NEC LCD, unknown response: #{data[10..13]}"
        logger.info "-- NEC LCD, full response was: #{data}"
      end
  end

  # Types of messages sent to and from the LCD
  enum MsgType
    Command             = 0x41 # 'A'
    Command_reply       = 0x42 # 'B'
    Get_parameter       = 0x43 # 'C'
    Get_parameter_reply = 0x44 # 'D'
    Set_parameter       = 0x45 # 'E'
    Set_parameter_reply = 0x46 # 'F'
  end

  OPERATION_NAMES = [
    :video_input,
    :audio_input,
    :volume_status,
    :mute_status,
    :power_on_delay,
    :contrast_status,
    :brightness_status,
    :auto_setup
  ]

  OPERATION_VALUES = [
    Bytes[0x00, 0x60],
    Bytes[0x02, 0x2E],
    Bytes[0x00, 0x62],
    Bytes[0x00, 0x8D],
    Bytes[0x02, 0xD8],
    Bytes[0x00, 0x12],
    Bytes[0x00, 0x10],
    Bytes[0x00, 0x1E]
  ]

  {% for name, index in OPERATION_NAMES %}
  @[Security(Level::Administrator)]
    def {{name.id}}(priority : Int32 = 0)
      data = OPERATION_VALUES[{{index}}]
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
  private def do_send(type : String, data : Bytes = Bytes.empty, **options)
    bytes = Bytes.new(data.size + 7)
    bytes[0] = 0x01                                 # SOH
    bytes[1] = MsgType.parse(type).to_u8            #
    bytes[2] = data.size.to_u8 + 2                  # Length
    bytes[3] = 0x02                                 #
    data.each_with_index(4) { |b, i| bytes[i] = b } # Data
    bytes[-3] = 0x03                                #
    checksum = 0x00_u8
    bytes[1..-3].each do |b|
      checksum = checksum ^ b
    end
    bytes[-2] = checksum                            # Checksum
    bytes[-1] = DELIMITER                           # Delimiter

    send(bytes, **options)
  end
end