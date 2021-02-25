require "digest/md5"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/camera"

# require "tokenizer"

module Wolfvision; end

# Documentation: https://www.wolfvision.com/wolf/protocol_command_wolfvision/protocol/commands_eye-14.pdf
# Ruby version: https://github.com/acaprojects/ruby-engine-drivers/tree/beta/modules/wolfvision

class Wolfvision::Eye14 < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Camera
  include Interface::Powerable
  include Interface::Muteable

  # include PlaceOS::Driver::Interface::InputSelection(Power)
  @channel : Channel(String) = Channel(String).new
  @stable_power : Bool = true

  tcp_port 50915 # Need to go through an RS232 gatway
  descriptive_name "WolfVision EYE-14"
  generic_name :Camera

  COMMANDS = {
    power_on:        "\x01\x30\x01\x01",
    power_off:       "\x01\x30\x01\x00",
    power_query:     "\x00\x30\x00",
    autofocus:       "\x01\x31\x01\x01",
    autofocus_query: "\x00\x31\x00",
    iris:            "\x01\x22\x02",
    iris_query:      "\x00\x22\x00",
  }
  RESPONSES = COMMANDS.to_h.invert

  # delay between_sends: 150

  def on_load
    # transport.tokenizer = Tokenizer.new("\r")
    transport.tokenizer = Tokenizer.new(/\x00|\x01|/)

    @zoom_range = 0..3923
    @iris_range = 0..4094

    on_update
  end

  def on_update
  end

  def on_unload
  end

  def connected
    schedule.every(60.seconds) do
      logger.debug { "-- Polling Sony Camera" }

      if power? && self[:power] == PowerState::On
        zoom?
        iris?
        autofocus?
      end
    end
  end

  def disconnected
    # Disconnected will be called before connect if initial connect fails
    @channel.close unless @channel.closed?
  end

  def power(state : Bool)
    self[:stable_power] = @stable_power = false
    self[:power_target] = state

    if state
      logger.debug { "requested to power on" }
      do_send(:power_on, retries: 10, name: :power_on, delay: 8.seconds)
    else
      logger.debug { "requested to power off" }
      do_send(:power_off, retries: 10, name: :power_off, delay: 8.seconds) # .get

    end
  end

  # uses only optical zoom
  def zoom(position : String = "")
    val = in_range(position, @zoom_range.max, @zoom_range.min)
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

  def iris(position : String = "")
    val = in_range(position, @iris_range.max, @iris_range.min)
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
    !!self[:power]?.try(&.as_bool)
  end

  def send_cmd(cmd : String = "", **options)
    req = "\x01#{cmd}"
    logger.debug { "tell -- 0x#{byte_to_hex(req)} -- #{options[:name]}" }
    # @channel.send(req, options)
    @channel.send(req)
  end

  def send_inq(inq : String = "", **options)
    req = "\x00#{inq}"
    logger.debug { "ask -- 0x#{byte_to_hex(req)} -- #{options[:name]}" }
    # @channel.send(req, options)
    @channel.send(req)
  end

  def received(data : Slice = Slice.empty, command : PlaceOS::Driver::Task = "null")
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

  def check_length(byte_str : String = "")
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

  def byte_to_hex(data : String = "")
    # data.split(//)
    data.hexbytes
    # output = ""
    # data.each_byte { |c|
    #     s = c.as(String).to_s(16)
    #     s.prepend('0') if s.length % 2 > 0
    #     output << s
    # }
    # return output
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = COMMANDS[command]

    logger.debug { "queuing #{command}: #{cmd}" }

    # queue the request
    queue(**({
      name: command,
    }.merge(options))) do
      # prepare channel and connect to the projector (which will then send the random key)
      @channel = Channel(String).new
      transport.connect
      # wait for the random key to arrive
      random_key = @channel.receive
      # send the request
      # NOTE:: the built in `send` function has implicit queuing, but we are
      # in a task callback here so should be calling transport send directly
      transport.send(cmd)
    end
  end
end
