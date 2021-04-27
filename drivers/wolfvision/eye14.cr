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
  # include PlaceOS::Driver::Interface::Camera

  # include PlaceOS::Driver::Interface::InputSelection(Power)
  @channel : Channel(String) = Channel(String).new
  @stable_power : Bool = true

  @zoom_range = 0..3923
  @iris_range = 0..4094

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

  def on_load
    transport.tokenizer = Tokenizer.new("\r")
    on_update
  end

  def on_update
  end

  def on_unload
  end

  def connected
    schedule.clear
    schedule.every(60.seconds) do
      logger.info { "-- Polling Wolfvision Eye14 Camera" }

      if power? && self[:power] == true
        zoom?
        iris?
        autofocus?
      end
    end
  end

  def disconnected
    # transport.disconnect
    # Disconnected will be called before connect if initial connect fails
    @channel.close unless @channel.closed?
  end

  ####
  # Power controls
  # On / Off
  #
  def power(state : Bool)
    logger.info { "requested to power -  #{state}" }
    self[:stable_power] = @stable_power = false
    self[:power_target] = state
    if state
      do_send(:power_on, retries: 10, name: :power_on, delay: 2.seconds)
    else
      do_send(:power_off, retries: 10, name: :power_off, delay: 2.seconds).get
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
  def zoom(position : String | Int32 = 0)
    val = position if @zoom_range.includes?(position.to_i32)
    self[:zoom_target] = val
    val = val.to_i.chr if !val.nil?
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
    do_send(:autofocus, priority: 0, name: :autofocus)
  end

  def autofocus?
    do_send(:autofocus_query, priority: 0, name: :autofocus_query)
  end

  ####
  # Iris aperture controls
  #
  def iris(position : String | Int32 = 0)
    val = position if @zoom_range.includes?(position.to_i32)
    self[:iris_target] = val
    val = val.to_i.chr if !val.nil?
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
    logger.info { "Wolfvision eye14 sent reply: #{data} and Task name is #{task.try &.name}" }

    # We can't interpret this message without a task reference
    # This also makes sure it is no longer nil
    return unless task

    # Process the response

    hex_int = data.hexstring.chars[0..9]

    # array holding the hex string pairs
    hex_arr = [] of String
    hex_int.each_with_index do |v, k|
      hex_arr << "#{hex_int[k - 1]}#{hex_int[k]}" if k % 2 == 1
    end

    case task.name
    when "power_on"
      self[:power] = true if hex_arr[1] == "30"
      self[:stable_power] = @stable_power = true
    when "power_off"
      self[:power] = false if hex_arr[1] == "30"
      self[:stable_power] = @stable_power = true
    when "power_query"
      self[:power] = (hex_arr[3].to_i == 1) ? true : false
    when "zoom"
      self[:zoom] = self[:zoom_target] if hex_arr[1] == "20"
    when "zoom_query"
      self[:zoom] = hex_arr[4].to_i(16) if hex_arr[1] == "20"
    when "iris"
      self[:iris] = self[:iris_target] if hex_arr[1] == "22"
    when "iris_query"
      self[:iris] = hex_arr[4].to_i(16) if hex_arr[1] == "22"
    when "autofocus"
      self[:autofocus] = true if hex_arr[1] == "31"
    when "autofocus_query"
      self[:autofocus] = (hex_arr[2].to_i == 1) ? true : false
    else
      raise Exception.new(" Could not process task #{task.name} from eye14. \r\nData: #{data}")
    end

    # transport.disconnect
    return task.try &.success
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    # puts param

    cmd = if param.nil?
            "#{COMMANDS[command]}"
          else
            "#{COMMANDS[command]}#{param}"
          end

    logger.info { " Queing: #{cmd}" }

    # queue the request
    queue(**({
      name: command,
    }.merge(options))) do
      # prepare channel and connect to the projector (which will then send the random key)
      @channel = Channel(String).new
      # send the request
      logger.info { " Sending: #{cmd}" }
      transport.send(cmd)
    end
  end
end
