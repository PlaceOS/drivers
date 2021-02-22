module Wolfvision; end

# Documentation: https://www.wolfvision.com/wolf/protocol_command_wolfvision/protocol/commands_eye-14.pdf
# Ruby version: https://github.com/acaprojects/ruby-engine-drivers/tree/beta/modules/wolfvision

class Wolfvision::Eye14 < PlaceOS::Driver
  # TODO: Implement PlaceOS::Driver::Interface::Zoomable

  # include ::Orchestrator::Constants
  include PlaceOS::Driver::Utilities::Transcoder

  tcp_port 50915 # Need to go through an RS232 gatway
  descriptive_name "WolfVision EYE-14"
  generic_name :Camera

  # Communication settings
  tokenize indicator: /\x00|\x01|/, callback: :check_length
  delay between_sends: 150

  def on_load
    self[:zoom_max] = 3923
    self[:iris_max] = 4094
    self[:zoom_min] = self[:iris_min] = 0
    on_update
  end

  def on_update
  end

  def on_unload
  end

  def connected
    schedule.every("60s") do
      logger.debug "-- Polling Sony Camera"
      power? do
        if self[:power] == On
          zoom?
          iris?
          autofocus?
        end
      end
    end
  end

  def disconnected
    # Disconnected will be called before connect if initial connect fails
    schedule.clear
  end

  def power(state)
    target = is_affirmative?(state)
    self[:power_target] = target

    # Execute command
    logger.debug { "Target = #{target} and self[:power] = #{self[:power]}" }
    if target == On && self[:power] != On
      send_cmd("\x30\x01\x01", name: :power_cmd)
    elsif target == Off && self[:power] != Off
      send_cmd("\x30\x01\x00", name: :power_cmd)
    end
  end

  # uses only optical zoom
  def zoom(position)
    val = in_range(position, self[:zoom_max], self[:zoom_min])
    self[:zoom_target] = val
    val = sprintf("%04X", val)
    logger.debug { "position in decimal is #{position} and hex is #{val}" }
    send_cmd("\x20\x02#{hex_to_byte(val)}", name: :zoom_cmd)
  end

  def zoom?
    send_inq("\x20\x00", priority: 0, name: :zoom_inq)
  end

  # set autofocus to on
  def autofocus
    send_cmd("\x31\x01\x01", name: :autofocus_cmd)
  end

  def autofocus?
    send_inq("\x31\x00", priority: 0, name: :autofocus_inq)
  end

  def iris(position)
    val = in_range(position, self[:iris_max], self[:iris_min])
    self[:iris_target] = val
    val = sprintf("%04X", val)
    logger.debug { "position in decimal is #{position} and hex is #{val}" }
    send_cmd("\x22\x02#{hex_to_byte(val)}", name: :iris_cmd)
  end

  def iris?
    send_inq("\x22\x00", priority: 0, name: :iris_inq)
  end

  def power?
    send_inq("\x30\x00", priority: 0, name: :power_inq)
  end

  def send_cmd(cmd, options = Hash.new)
    req = "\x01#{cmd}"
    logger.debug { "tell -- 0x#{byte_to_hex(req)} -- #{options[:name]}" }
    send(req, options)
  end

  def send_inq(inq, options = Hash.new)
    req = "\x00#{inq}"
    logger.debug { "ask -- 0x#{byte_to_hex(req)} -- #{options[:name]}" }
    send(req, options)
  end

  def received(data, deferrable, command)
    logger.debug { "Received 0x#{byte_to_hex(data)}\n" }

    bytes = str_to_array(data)

    if command && !command[:name].nil?
      case command[:name]
      when :power_cmd
        self[:power] = self[:power_target] if byte_to_hex(data) == "3000"
      when :zoom_cmd
        self[:zoom] = self[:zoom_target] if byte_to_hex(data) == "2000"
      when :iris_cmd
        self[:iris] = self[:iris_target] if byte_to_hex(data) == "2200"
      when :autofocus_cmd
        self[:autofocus] = true if byte_to_hex(data) == "3100"
      when :power_inq
        # -1 index for array refers to the last element in Ruby
        self[:power] = bytes[-1] == 1
      when :zoom_inq
        # for some reason the after changing the zoom position
        # the first zoom inquiry sends "2000" regardless of the actaul zoom value
        # consecutive zoom inquiries will then return the correct zoom value

        return :ignore if byte_to_hex(data) == "2000"
        hex = byte_to_hex(data[-2..-1])
        self[:zoom] = hex.to_i(16)
      when :autofocus_inq
        self[:autofocus] = bytes[-1] == 1
      when :iris_inq
        # same thing as zoom inq happens here
        return :ignore if byte_to_hex(data) == "2200"
        hex = byte_to_hex(data[-2..-1])
        self[:iris] = hex.to_i(16)
      else
        return :ignore
      end
      return :success
    end
  end

  def check_length(byte_str : String)
    # response = str_to_array(byte_str)
    response = byte_str.to_a

    return false if response.length <= 1 # header is 2 bytes

    len = response[1] + 2 # (data length + header)

    if response.length >= len
      return len
    else
      return false
    end
  end
end
