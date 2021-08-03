require "digest/md5"
require "placeos-driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

#
module Denon; end

module Denon::Amplifier; end

# Protocol: https://aca.im/driver_docs/Denon/Denon%20AVR%20PROTOCOL%20V7.5.0.pdf
#
#     NOTE:: Denon doesn't respond to commands that request the current state
#         (ie if the volume is 100 and you request 100 it will not respond)
#

class Denon::Amplifier::AvReceiver < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Utilities::Transcoder

  @channel : Channel(String) = Channel(String).new
  @stable_power : Bool = true

  COMMANDS = {
    power:        :PW,
    power_query:  :PW?,
    mute:         :MU,
    mute_query:   :MU?,
    volume:       :MV,
    volume_query: :MV?,
    input:        :SI,
    input_query:  :SI?,
  }
  COMMANDS.to_h.merge!(COMMANDS.to_h.invert)

  @volume_range = 0..196

  default_settings({
    max_waits: 10,
    timeout:   3000,
  })
  # Discovery Information
  tcp_port 23 # Telnet
  descriptive_name "Denon AVR (Switcher Amplifier)"
  generic_name :Switcher

  # Denon requires some breathing room
  # delay between_sends: 30
  # delay on_receive: 30

  def on_load
    # transport.tokenizer = Tokenizer.new(Bytes[0x0D])
    transport.tokenizer = Tokenizer.new("\r")
    self[:volume_min] = 0
    self[:volume_max] = @volume_range.max # == 98 * 2    - Times by 2 so we can account for the half steps
    on_update
  end

  def on_update
    self[:max_waits] = 10
    self[:timeout] = 3000
  end

  def connected
    #
    # Get state
    #
    # power?
    # input?
    # mute?

    schedule.every(60.seconds) do
      logger.info { "-- Polling Denon AVR" }
      power?
      do_send(:input, priority: 0, name: :input)
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool = false)
    # self[:power] is current as we would be informed otherwise
    if state && (self[:power] == "OFF" || self[:power] == "STANDBY") # Request to power on if off
      do_send(:power, "ON", delay: 3.milliseconds, name: :power)     # Manual states delay for 1 second, just to be safe
    elsif !state && self[:power] == "ON"                             # Request to power off if on
      do_send(:power, "STANDBY", delay: 3.milliseconds, name: :power)
    end
  end

  def power?
    # def power?(**options)
    # options[:emit] = {:power => block} unless block.nil?
    do_send(:power_query, priority: 0, name: :power_query)
  end

  def mute?
    self[:mute] = "OFF"
    do_send(:mute_query, priority: 0, name: :mute_query)
  end

  def mute(state : Bool = true)
    req = state ? "ON" : "OFF"
    return if self[:mute] == req
    do_send(:mute, req, name: :mute)
  end

  def mute_audio(state : Bool = true)
    mute state
  end

  def unmute
    mute false
  end

  def unmute_audio
    unmute
  end

  def volume(level : Int32 = 0)
    value = 0
    value = level if @volume_range.includes?(level.to_i)

    return if self[:volume] == value

    # The denon is weird 99 is volume off,
    # 99.5 is the minimum volume,
    # 0 is the next lowest volume and 985 is the loudest volume
    # => So we are treating 99, 995 and 0 as 0
    step = value % 2
    actual = value / 2
    req = actual.to_s.rjust(2, '0')
    req += "5" if step != 0

    do_send(:volume, req, name: :volume) # Name prevents needless queuing of commands

  end

  def volume?
    do_send(:volume_query, priority: 0, name: :volume_query)
  end

  # Just here for documentation (there are many more)
  #
  # INPUTS = [:cd, :tuner, :dvd, :bd, :tv, :"sat/cbl", :dvr, :game, :game2, :"v.aux", :dock]
  def input(input : String = "")
    status = input.upcase # .downcase.to_sym
    if status != self[:input]
      input = input.to_s.upcase
      do_send(:input, input, name: :input)
    end
  end

  def input?
    do_send(:input_query, priority: 0, name: :input_query)
  end

  def received(data, task)
    data = String.new(data)
    logger.info { "Denon sent #{data.inspect}" }

    return unless task

    # Process the response
    cmd = data[0..1]  # first 2 chars are the key / command
    val = data[2..-2] # anything following the above and before \r is a response value

    case cmd
    when "PW"
      self[:power] = val
    when "SI"
      self[:input] = val
    when "MV"
      # return :ignore if val.chars.size > 3 # May send 'MVMAX 98' after volume command
      # self[:volume] = 0
      # vol = val.to_i32
      # self[:volume] = val unless val.to_i32 > @volume_range.max
      self[:volume] = val
      #    return :ignore if param.length > 3 # May send 'MVMAX 98' after volume command
      #    vol = param[0..1].to_i * 2
      #    vol += 1 if param.length == 3
      #    vol == 0 if vol > @volume_range.max # this means the volume was 99 or 995
      #    self[:volume] = vol

    when "MU"
      self[:mute] = val
    else
      return :ignore
    end

    task.try &.success
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = if param.nil?
            "#{COMMANDS[command]}"
          else
            "#{COMMANDS[command]}#{param}"
          end
    logger.info { "Queing: #{cmd}" }

    # queue the request
    queue(**({
      name: command,
    }.merge(options))) do
      @channel = Channel(String).new
      # send the request
      logger.info { " Sending: #{cmd}" }
      transport.send(cmd)
    end
  end
end
