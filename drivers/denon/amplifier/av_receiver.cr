require "digest/md5"
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

  @channel : Channel(String) = Channel(String).new
  @stable_power : Bool = true

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
    transport.tokenizer = Tokenizer.new(Bytes[0x0D])
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
    do_send(COMMANDS[:power])
    do_send(COMMANDS[:input])
    do_send(COMMANDS[:volume])
    do_send(COMMANDS[:mute])

    schedule.every(60.seconds) do
      logger.debug { "-- Polling Denon AVR" }
      power?
      do_send(COMMANDS[:input], priority: 0)
    end
  end

  def disconnected
    schedule.clear
  end

  COMMANDS = {
    power:  :PW,
    mute:   :MU,
    volume: :MV,
    input:  :SI,
  }
  COMMANDS.to_h.merge!(COMMANDS.to_h.invert)

  def power(state : Bool)
    # self[:power] is current as we would be informed otherwise
    if state && !self[:power]                                                           # Request to power on if off
      do_send(COMMANDS[:power], "ON", timeout: 10, delay: 3.milliseconds, name: :power) # Manual states delay for 1 second, just to be safe

    elsif !state && self[:power] # Request to power off if on
      do_send(COMMANDS[:power], "STANDBY", timeout: 10, delay: 3.milliseconds, name: :power)
    end
  end

  def power?
    # def power?(**options)
    # options[:emit] = {:power => block} unless block.nil?
    do_send(COMMANDS[:power], priority: 0)
  end

  def mute(state : Bool = true)
    # will_mute = is_affirmative?(state)
    req = state ? "ON" : "OFF"
    return if self[:mute] == state
    do_send(COMMANDS[:mute], req)
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

    # The denon is weird 99 is volume off, 99.5 is the minimum volume, 0 is the next lowest volume and 985 is the loudest volume
    # => So we are treating 99, 995 and 0 as 0
    step = value % 2
    actual = value / 2
    req = actual.to_s.rjust(2, '0')
    req += "5" if step != 0

    do_send(COMMANDS[:volume], req, name: :volume) # Name prevents needless queuing of commands
    self[:volume] = value
  end

  # Just here for documentation (there are many more)
  #
  # INPUTS = [:cd, :tuner, :dvd, :bd, :tv, :"sat/cbl", :dvr, :game, :game2, :"v.aux", :dock]
  def switch_to(input : String = "")
    status = input # .downcase.to_sym
    if status != self[:input]
      input = input.to_s.upcase
      do_send(COMMANDS[:input], input, name: :input)
      self[:input] = status
    end
  end

  def received(data, task)
    # data = String.new(data).rchop
    logger.debug { "Denon sent #{data}" }
    logger.debug { "INFO: Denon sent #{data}" }

    #  comm = data[0..1].to_sym
    #  param = data[2..-1]

    #  case COMMANDS[comm]
    #  when :power
    #    self[:power] = param == "ON"
    #  when :input
    #    self[:input] = param.downcase.to_sym
    #  when :volume
    #    return :ignore if param.length > 3 # May send 'MVMAX 98' after volume command

    #    vol = param[0..1].to_i * 2
    #    vol += 1 if param.length == 3

    #    vol == 0 if vol > @volume_range.max # this means the volume was 99 or 995

    #    self[:volume] = vol
    #  when :mute
    #    self[:mute] = param == "ON"
    #  else
    #    return :ignore
    #  end
    true
    # task.success
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = if param.nil?
            "#{COMMANDS[command]}\r"
          else
            "#{COMMANDS[command]}#{param}\r"
          end

    logger.debug { "queuing #{command}: #{cmd}" }
    send(cmd)
    # queue the request
    #   queue(**({
    #      name: command,
    #    }.merge(options))) do
    # prepare channel and connect to the projector (which will then send the random key)
    #      @channel = Channel(String).new
    #      transport.connect
    # wait for the random key to arrive
    # random_key = @channel.receive
    # send the request
    # NOTE:: the built in `send` function has implicit queuing, but we are
    # in a task callback here so should be calling transport send directly
    #      transport.send(cmd)
    #    end
  end
end
