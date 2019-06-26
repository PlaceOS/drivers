require "digest/md5"
require "engine-driver/interface/powerable"

module Panasonic; end

module Panasonic::Projector; end

# Documentation: https://aca.im/driver_docs/Panasonic/panasonic_pt-vw535n_manual.pdf
#  also https://aca.im/driver_docs/Panasonic/pt-ez580_en.pdf

# How the projector expects you interact with it:
# ===============================================
# 1. New connection required for each command sent (hence makebreak!)
# 2. On connect, the projector sends you a string of characters to use as a password salt
# 3. Encode your message using the salt and send it to the projector
# 4. Projector responds with a value
# 5. You have to disconnect explicitly, projector won't close the connection

class Panasonic::Projector::NTControl < EngineDriver
  include EngineDriver::Interface::Powerable

  # Discovery Information
  tcp_port 1024
  descriptive_name "Panasonic Projector"
  generic_name :Display
  default_settings({username: "admin1", password: "panasonic"})
  makebreak!

  def on_load
    # Communication settings
    transport.tokenizer = Tokenizer.new("\r")

    schedule.every(40.seconds) do
      power?(priority: 0)
      lamp_hours?(priority: 0)
    end

    on_update
  end

  def disconnected
    @channel.close unless @channel.closed?
  end

  @username : String = "admin1"
  @password : String = "panasonic"

  # used to coordinate the projector password hash
  @channel : Channel(String) = Channel(String).new
  @stable_power : Bool = true

  def on_update
    @username = setting?(String, :username) || "admin1"
    @password = setting?(String, :password) || "panasonic"
  end

  COMMANDS = {
    power_on:    "PON",
    power_off:   "POF",
    power_query: "QPW",
    freeze:      "OFZ",
    input:       "IIS",
    mute:        "OSH",
    lamp:        "Q$S",
    lamp_hours:  "Q$L",
  }
  RESPONSES = COMMANDS.to_h.invert

  def power(state : Bool)
    self[:stable_power] = @stable_power = false
    self[:power_target] = state

    if state
      logger.debug "requested to power on"
      do_send(:power_on, retries: 10, name: :power, delay: 8.seconds)
      do_send(:lamp)
    else
      logger.debug "requested to power off"
      do_send(:power_off, retries: 10, name: :power, delay: 8.seconds).get

      # Schedule this after we have a result for the power function
      # As the projector does not even update to cooling for awhile
      schedule.in(10.seconds) { do_send(:lamp) }
    end
  end

  def power?(**options)
    do_send(:lamp, **options)
  end

  def lamp_hours?(**options)
    do_send(:lamp_hours, 1, **options)
  end

  enum Inputs
    HDMI
    HDMI2
    VGA
    VGA2
    Miracast
    DVI
    DisplayPort
    HDBaseT
    Composite
  end

  INPUTS = {
    Inputs::HDMI        => "HD1",
    Inputs::HDMI2       => "HD2",
    Inputs::VGA         => "RG1",
    Inputs::VGA2        => "RG2",
    Inputs::Miracast    => "MC1",
    Inputs::DVI         => "DVI",
    Inputs::DisplayPort => "DP1",
    Inputs::HDBaseT     => "DL1",
    Inputs::Composite   => "VID",
  }
  INPUT_LOOKUP = INPUTS.invert

  def switch_to(input : Inputs)
    # Projector doesn't automatically unmute
    unmute if self[:mute]

    do_send(:input, INPUTS[input], delay: 2.seconds)
    logger.debug { "requested to switch to: #{input}" }

    self[:input] = input # for a responsive UI
  end

  # Mutes audio + video
  def mute(state : Bool = true)
    logger.debug { "requested mute state: #{state}" }

    actual = state ? 1 : 0
    do_send(:mute, actual)
  end

  def unmute
    mute false
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
    logger.debug { "Panasonic sent: #{data}" }

    # This is sent by the projector on initial connection
    # the channel is used to send the hash salt to the task sending a command
    if data.starts_with? "NTCONTROL"
      # check for protected mode
      if @channel && !@channel.closed?
        # 1 == protected mode
        @channel.send(data[10] == '1' ? data[12..-1] : "")
      else
        transport.disconnect
      end
      return
    end

    # we no longer need the connection to be open , the projector expects
    # us to close it and a new connection is required per-command
    transport.disconnect

    # Check for error response
    if data[0] == 'E'
      self[:last_error] = error_msg = ERRORS[data]

      if {"ERR3", "ERR4"}.includes? data
        logger.info "projector busy: #{error_msg} (#{data})"
        task.try &.retry
      else
        logger.error "projector error: #{error_msg} (#{data})"
        task.try &.abort(error_msg)
      end
      return
    end

    # We can't interpret this message without a task reference
    # This also makes sure it is no longer nil
    return unless task

    # Process the response
    data = data[2..-1]
    resp = data.split(':')
    cmd = RESPONSES[resp[0]]?
    val = resp[1]?

    case cmd
    when :power_on
      self[:power] = true
    when :power_off
      self[:power] = false
    when :power_query
      self[:power] = val.not_nil!.to_i == 1
    when :freeze
      self[:frozen] = val.not_nil!.to_i == 1
    when :input
      self[:input] = INPUT_LOOKUP[val]
    when :mute
      self[:mute] = val.not_nil!.to_i == 1
    else
      case task.name
      when "lamp"
        ival = resp[0].to_i
        self[:power] = {1, 2}.includes?(ival)
        self[:warming] = ival == 1
        self[:cooling] = ival == 3

        # check target states here
        if !@stable_power
          if self[:power] == self[:power_target]
            self[:stable_power] = @stable_power = true
          else
            power self[:power_target].as_bool
          end
        end
      when "lamp_hours"
        # Resp looks like: "001682"
        self[:lamp_usage] = data.to_i
      end
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
      # prepare channel and connect to the projector (which will then send the random key)
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
