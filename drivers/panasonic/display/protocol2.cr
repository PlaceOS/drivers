require "digest/md5"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

# Based off the very similar https://github.com/PlaceOS/drivers/blob/master/drivers/panasonic/display/nt_control.cr

# How the display expects you interact with it:
# ===============================================
# 1. New connection required for each command sent (hence makebreak!)
# 2. On connect, the display sends you a string of characters to use as a password salt
# 3. Encode your message using the salt and send it to the display
# 4. Display responds with a value
# 5. You have to disconnect explicitly, display won't close the connection

class Panasonic::Display::Protocol2 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Inputs
    HDMI
    HDMI2
    VGA
    DVI
  end
  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  # Discovery Information
  tcp_port 1024
  descriptive_name "Panasonic Display Protocol 2"
  generic_name :Display
  default_settings({username: "admin1", password: "panasonic"})
  makebreak!

  def on_load
    # Communication settings
    transport.tokenizer = Tokenizer.new("\r")

    schedule.every(60.seconds) { do_poll }

    on_update
  end

  def disconnected
    @channel.close unless @channel.closed?
  end

  @username : String = "admin1"
  @password : String = "panasonic"

  # used to coordinate the display password hash
  @channel : Channel(String) = Channel(String).new
  @power_target : Bool? = nil

  def on_update
    @username = setting?(String, :username) || "dispadmin"
    @password = setting?(String, :password) || "@Panasonic"
  end

  COMMANDS = {
    power_on:     "PON",
    power_off:    "POF",
    power_query:  "QPW",
    input:        "IMS",
    volume:       "AVL",
    volume_query: "QAV",
    audio_mute:   "AMT"
  }
  RESPONSES = COMMANDS.to_h.invert

  def power(state : Bool)
    @power_target = state

    if state
      logger.debug { "requested to power on" }
      do_send(:power_on, retries: 10, name: :power, delay: 8.seconds)
    else
      logger.debug { "requested to power off" }
      do_send(:power_off, retries: 10, name: :power, delay: 8.seconds)
    end
    power?
  end

  def power?(**options) : Bool
    do_send(:power_query, **options).get
    !!self[:power]?.try(&.as_bool)
  end

  INPUTS = {
    Inputs::HDMI  => "HM1",
    Inputs::HDMI2 => "HM2",
    Inputs::VGA   => "PC1",
    Inputs::DVI   => "DVI"
  }
  INPUT_LOOKUP = INPUTS.invert

  def switch_to(input : Inputs)
    logger.debug { "requested to switch to: #{input}" }
    do_send(:input, INPUTS[input], delay: 2.seconds)
    self[:input] = input # for a responsive UI
  end

  # There is no input query command
  def input?
    self[:input]?
  end

  # There is no video mute command so this only mutes audio
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "requested mute state: #{state}" }
    actual = state ? 1 : 0
    do_send(:audio_mute, actual)
  end

  def mute? : Bool
    do_send(:audio_mute).get
    !!self[:audio_mute]?.try(&.as_bool)
  end

  def volume(val : Int32)
    # Unable to query current volume
    do_send(:volume, val.to_s.rjust(3, '0')).get
    self[:volume] = val
  end

  def volume? : Int32?
    do_send(:volume_query).get
    self[:volume]?.try(&.as_i)
  end

  def do_poll
    if power?(priority: 0)
      mute?
      volume?
    end
  end

  ERRORS = {
    "ERR1"  => "1: Undefined control command",
    "ERR2"  => "2: Out of parameter range",
    "ERR3"  => "3: Busy state or no-acceptable period",
    "ERR4"  => "4: Timeout or no-acceptable period",
    "ERR5"  => "5: Wrong data length",
    "ERRA"  => "A: Password mismatch",
    "ER401" => "401: Command cannot be executed",
    "ER402" => "402: Invalid parameter is sent",
  }

  def received(data, task)
    data = String.new(data).strip
    logger.debug { "Panasonic display sent: #{data} for #{task.try(&.name) || "unknown"}" }

    # This is sent by the display on initial connection
    # the channel is used to send the hash salt to the task sending a command
    if data.starts_with?("NTCONTROL")
      # check for protected mode
      if @channel && !@channel.closed?
        # 1 == protected mode
        @channel.send(data[10] == '1' ? data[12..-1] : "")
      else
        transport.disconnect
      end
      return
    end

    # we no longer need the connection to be open , the display expects
    # us to close it and a new connection is required per-command
    transport.disconnect

    # remove the leading 00
    data = data[2..-1]

    # Check for error response
    if data[0] == 'E'
      self[:last_error] = error_msg = ERRORS[data]

      if {"ERR3", "ERR4"}.includes?(data)
        logger.info { "display busy: #{error_msg} (#{data})" }
        task.try(&.retry)
      else
        logger.error { "display error: #{error_msg} (#{data})" }
        task.try(&.abort(error_msg))
      end
      return
    end

    # We can't interpret this message without a task reference
    # This also makes sure it is no longer nil
    return unless task

    # Process the response
    resp = data.split(':')
    cmd = RESPONSES[resp[0]]?
    val = resp[1]?

    case cmd
    when :power_on, :power_off, :power_query
      self[:power] = cmd == :power_on if cmd == :power_on || cmd == :power_off
      self[:power] = val.not_nil!.to_i == 1 if cmd == :power_query

      # Ensure selected power state is achieved
      if power_target = @power_target
        if self[:power] == power_target
          @power_target = nil
        else
          power(power_target)
        end
      end
    when :input
      self[:input] = INPUT_LOOKUP[val]
    when :volume, :volume_query
      self[:volume] = val.not_nil!.to_i
    when :audio_mute
      self[:audio_mute] = val.not_nil!.to_i == 1
    end

    task.success
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = if param.nil?
            "00#{COMMANDS[command]}\r"
          else
            "00#{COMMANDS[command]}:#{param}\r"
          end

    logger.debug { "queuing #{command}: #{cmd}" }

    # queue the request
    queue(**({
      name: command,
    }.merge(options))) do
      # prepare channel and connect to the display (which will then send the random key)
      @channel = Channel(String).new
      transport.connect
      # wait for the random key to arrive
      random_key = @channel.receive
      # build the password hash
      password_hash = if random_key.empty?
                        # An empty key indicates unauthenticated mode
                        ""
                      else
                        Digest::MD5.hexdigest("#{@username}:#{@password}:#{random_key}")
                      end

      message = "#{password_hash}#{cmd}"
      logger.debug { "Sending: #{message}" }

      # send the request
      # NOTE:: the built in `send` function has implicit queuing, but we are
      # in a task callback here so should be calling transport send directly
      transport.send(message)
    end
  end
end
