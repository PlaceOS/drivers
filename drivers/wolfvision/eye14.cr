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
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Utilities::Transcoder
  include PlaceOS::Driver::Interface::Camera

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
    zoom:            "\x01\x20\x02",
    zoom_query:      "\x00\x20\x00",
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

  ####
  # Implement for interfaces else crystal cries
  #
  def move(position : MoveablePosition, index : Int32 | String = 0)
  end

  def stop(index : Int32 | String = 0, emergency : Bool = false)
  end

  def joystick(pan_speed : Int32, tilt_speed : Int32, index : Int32 | String = 0)
  end

  def recall(position : String, index : Int32 | String = 0)
  end

  def save_position(name : String, index : Int32 | String = 0)
  end

  def connected
    schedule.every(60.seconds) do
      logger.debug { "-- Polling Sony Camera" }

      if power? && self[:power] == true
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

  ####
  # Power controls
  # On / Off
  #
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

  ####
  # Power query
  def power?
    do_send(:power_query, priority: 0, name: :power_query)
  end

  ####
  # Zoom settings
  # uses only optical zoom
  #
  # implement zoomable interface method
  def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 0)
    zoom(position)
  end

  # Old interface
  def zoom(position : String | Int32 = 0)
    val = position if @zoom_range.includes?(position)
    self[:zoom_target] = val
    val = "%04X" % val
    logger.debug { "position in decimal is #{position} and hex is #{val}" }
    do_send(:zoom, val, name: :zoom)
  end

  def zoom?
    do_send(:zoom_query, priority: 0, name: :zoom_query)
  end

  ####
  # Autofocus
  # set autofocus to on
  # curiously there is no off
  #
  def autofocus
    do_send(:autofocus, name: :autofocus)
  end

  def autofocus?
    do_send(:autofocus_query, priority: 0, name: :autofocus_query)
  end

  ####
  # Iris aperture controls
  #
  def iris(position : String | Int32 = 0)
    val = position if @zoom_range.includes?(position)
    self[:iris_target] = val
    val = "%04X" % val
    logger.debug { "position in decimal is #{position} and hex is #{val}" }
    do_send(:iris, val, name: :iris)
  end

  def iris?
    do_send(:iris_query, priority: 0, name: :iris_query)
  end

  ####
  # Called when signal from device is received
  # toghther with
  # `data` - containing the payload
  # `task` - continaing callee task
  #
  def received(data, task)
    data = String.new(data).strip
    logger.debug { "Wolfvision eye14 sent sent: #{data}" }

    # we no longer need the connection to be open , the projector expects
    # us to close it and a new connection is required per-command
    transport.disconnect

    # We can't interpret this message without a task reference
    # This also makes sure it is no longer nil
    return unless task

    # Process the response
    data = data[2..-1]
    hex = byte_to_hex(data[-2..-1])
    val = hex.to_i(16)

    case task.name
    when :power_on
      self[:power] = true if byte_to_hex(data) == "3000"
    when :power_off
      self[:power] = false if byte_to_hex(data) == "3000"
    when :power_query
      self[:power] = val.not_nil!.to_i == 1
    when :zoom
      self[:zoom] = self[:zoom_target] if byte_to_hex(data) == "2000"
    when :zoom_query
      self[:zoom] = val.not_nil!.to_i == 1
    when :iris
      self[:iris] = self[:iris_target] if byte_to_hex(data) == "2200"
    when :iris_query
      self[:iris] = val.not_nil!.to_i == 1
    when :autofocus
      self[:autofocus] = true if byte_to_hex(data) == "3100"
    when :autofocus_query
      self[:autofocus] = val.not_nil!.to_i == 1
    else
      raise Exception.new("could not process task #{task.name} from eye14. \r\nData: #{data}")
    end

    task.success
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = if param.nil?
            "#{COMMANDS[command]}"
          else
            "#{COMMANDS[command]}#{param}"
          end

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
