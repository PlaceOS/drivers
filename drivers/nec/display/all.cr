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
  # @input_double_check = nil

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
      do_send(:command, data, name: :power, delay: 10000, timeout: 10000)

      self[:power] = false
      logger.debug { "-- NEC LCD, requested to power off" }
    else
      data = Bytes[0xC2, 0x03, 0xD6, 0x00, 0x01] # 0001 = Power On
      do_send(:command, data, name: :power, delay: 5000)
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
    do_send(:command, Bytes[0x01, 0xD6], **options)
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

  # def switch_to(input)
  #   input = input.to_sym
  #   self[:target_input] = input
  #   self[:target_audio] = nil

  #   type = :set_parameter
  #   message = OPERATION_CODE[:video_input]
  #   message += INPUTS[input].to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

  #   do_send(type, message, name: :input, delay: 6000)
  #   video_input

  #   # Double check the input again!
  #   @input_double_check.cancel if @input_double_check
  #   @input_double_check = schedule.in('4s') do
  #       @input_double_check = nil
  #       video_input
  #   end

  #   logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
  # end

  # AUDIO = {
  #   :audio1 => 1,
  #   :audio2 => 2,
  #   :audio3 => 3,
  #   :hdmi => 4,
  #   :tv => 6,
  #   :display_port => 7
  # }
  # AUDIO.merge!(AUDIO.invert)

  # def switch_audio(input)
  #   input = input.to_sym if input.class == String
  #   self[:target_audio] = input

  #   type = :set_parameter
  #   message = OPERATION_CODE[:audio_input]
  #   message += AUDIO[input].to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

  #   do_send(type, message, name: :audio)
  #   mute_status(20)        # higher status than polling commands - lower than input switching
  #   volume_status(20)

  #   logger.debug { "-- NEC LCD, requested to switch audio to: #{input}" }
  # end


  # #
  # # Auto adjust
  # #
  # def auto_adjust
  #   message = OPERATION_CODE[:auto_setup] #"001E"    # Page + OP code
  #   message += "0001"    # Value of input as a hex string

  #   do_send(:set_parameter, message, delay_on_receive: 4000)
  # end


  # #
  # # Value based set parameter
  # #
  # def brightness(val)
  #   val = in_range(val.to_i, 100)

  #   message = OPERATION_CODE[:brightness_status]
  #   message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

  #   do_send(:set_parameter, message, name: :brightness)
  #   do_send(:command, '0C', name: :brightness_save)    # Save the settings
  # end

  # def contrast(val)
  #   val = in_range(val.to_i, 100)

  #   message = OPERATION_CODE[:contrast_status]
  #   message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

  #   do_send(:set_parameter, message, name: :contrast)
  #   do_send(:command, '0C', name: :contrast_save)    # Save the settings
  # end

  # def volume(val)
  #   val = in_range(val.to_i, 100)

  #   message = OPERATION_CODE[:volume_status]
  #   message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

  #   self[:audio_mute] = false    # audio is unmuted when the volume is set

  #   do_send(:set_parameter, message, name: :volume)
  #   do_send(:command, '0C', name: :volume_save)    # Save the settings
  # end


  # def mute_audio(state = true)
  #   message = OPERATION_CODE[:mute_status]
  #   message += is_affirmative?(state) ? "0001" : "0000"    # Value of input as a hex string

  #   do_send(:set_parameter, message, name: :mute)

  #   logger.debug { "requested to update mute to #{state}" }
  # end
  # alias_method :mute, :mute_audio

  # def unmute_audio
  #   mute_audio(false)
  # end
  # alias_method :unmute, :unmute_audio

  # LCD Response code
  def received(data, task)
  #   # Check for valid response
  #   if !check_checksum(data)
  #       logger.debug { "-- NEC LCD, checksum failed for command: #{command[:data]}" } if command
  #       logger.debug { "-- NEC LCD, response was: #{data}" }
  #       return false
  #   end

  #   logger.debug { "NEC LCD responded #{data}" }

  #   case MSG_TYPE[data[4]]    # Check the MSG_TYPE (B, D or F)
  #       when :command_reply
  #           #
  #           # Power on and off
  #           #    8..9 == "00" means no error 
  #           if data[10..15] == "C203D6"    # Means power comamnd
  #               if data[8..9] == "00"
  #                   power_on_delay(99)    # wait until the screen has turned on before sending commands (99 == high priority)
  #               else
  #                   logger.info "-- NEC LCD, command failed: #{command[:data]}" if command
  #                   logger.info "-- NEC LCD, response was: #{data}"
  #                   return false    # command failed
  #               end
  #           elsif data[10..13] == "00D6"    # Power status response
  #               if data[10..11] == "00"
  #                   if data[23] == '1'        # On == 1, Off == 4
  #                       self[:power] = On
  #                   else
  #                       self[:power] = Off
  #                       self[:warming] = false
  #                   end
  #               else
  #                   logger.info "-- NEC LCD, command failed: #{command[:data]}" if command
  #                   logger.info "-- NEC LCD, response was: #{data}"
  #                   return false    # command failed
  #               end

  #           end

  #       when :get_parameter_reply, :set_parameter_reply
  #           if data[8..9] == "00"
  #               parse_response(data, command)
  #           elsif data[8..9] == 'BE'    # Wait response
  #               send(command[:data])    # checksum already added
  #               logger.debug "-- NEC LCD, response was a wait command"
  #           else
  #               logger.info "-- NEC LCD, get or set failed: #{command[:data]}" if command
  #               logger.info "-- NEC LCD, response was: #{data}"
  #               return false
  #           end
  #   end

  #   return true # Command success
  end


  def do_poll
  #   power?({:priority => 0}) do
  #       logger.debug { "Polling, power = #{self[:power]}" }

  #       if self[:power] == On
  #           power_on_delay
  #           mute_status
  #           volume_status
  #           video_input
  #           audio_input
  #       end
  #   end
  end


  # private


  # def parse_response(data, command)

  #   # 14..15 == type (we don't care)
  #   max = data[16..19].to_i(16)
  #   value = data[20..23].to_i(16)

  #   case OPERATION_CODE[data[10..13]]
  #       when :video_input
  #           self[:input] = INPUTS[value]
  #           self[:target_input] = self[:input] if self[:target_input].nil?
  #           switch_to(self[:target_input]) unless self[:input] == self[:target_input]

  #       when :audio_input
  #           self[:audio] = AUDIO[value]
  #           switch_audio(self[:target_audio]) if self[:target_audio] && self[:audio] != self[:target_audio]

  #       when :volume_status
  #           self[:volume_max] = max
  #           if not self[:audio_mute]
  #               self[:volume] = value
  #           end

  #       when :brightness_status
  #           self[:brightness_max] = max
  #           self[:brightness] = value

  #       when :contrast_status
  #           self[:contrast_max] = max
  #           self[:contrast] = value

  #       when :mute_status
  #           self[:audio_mute] = value == 1
  #           if(value == 1)
  #               self[:volume] = 0
  #           else
  #               volume_status(60)    # high priority
  #           end

  #       when :power_on_delay
  #           if value > 0
  #               self[:warming] = true
  #               schedule.in("#{value}s") do        # Prevent any commands being sent until the power on delay is complete
  #                   power_on_delay
  #               end
  #           else
  #               schedule.in('3s') do        # Reactive the interface once the display is online
  #                   self[:warming] = false    # allow access to the display
  #               end
  #           end
  #       when :auto_setup
  #           # auto_setup
  #           # nothing needed to do here (we are delaying the next command by 4 seconds)
  #       else
  #           logger.info "-- NEC LCD, unknown response: #{data[10..13]}"
  #           logger.info "-- NEC LCD, for command: #{command[:data]}" if command
  #           logger.info "-- NEC LCD, full response was: #{data}"
  #   end
  # end

  # Types of messages sent to and from the LCD
  MSG_TYPE = Hash(Symbol|Char, Char|Symbol) {
    :command => 'A',
    'B' => :command_reply,
    :get_parameter => 'C',
    'D' => :get_parameter_reply,
    :set_parameter => 'E',
    'F' => :set_parameter_reply
  }

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

  # def check_checksum(data)
  #   data = str_to_array(data)

  #   check = 0
  #   #
  #   # Loop through the second to the second last element
  #   #    Delimiter is removed automatically
  #   #
  #   if data.length >= 2
  #       data[1..-2].each do |byte|
  #           check = check ^ byte
  #       end
  #       return check == data[-1]    # Check the check sum equals the last element
  #   else
  #       return true
  #   end
  # end

  # Builds the command and creates the checksum
  def do_send(type : Symbol, data : Bytes = Bytes.empty, **options)
    # #
    # # build header + command and convert to a byte array
    # #
    # command = "" << 0x02 << command << 0x03
    # command = "0*0#{MSG_TYPE[type]}#{command.length.to_s(16).upcase.rjust(2, '0')}#{command}"
    # command = str_to_array(command)

    # #
    # # build checksum
    # #
    # check = 0
    # command.each do |byte|
    #     check = check ^ byte
    # end

    # command << check    # Add checksum
    # command << 0x0D        # delimiter required by NEC displays
    # command.insert(0, 0x01)    # insert SOH byte (not part of the checksum)

    # send(command, options)
  end
end