require "digest/md5"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

module Epson; end

module Epson::Projector; end

# Documentation: documentation link

class Epson::Projector::EscVp21 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    HDMI    = 0x30
    HDBaseT = 0x80
  end

  # Discovery Information
  tcp_port 1024
  descriptive_name "Epson Projector"
  generic_name :Display

  def on_load
    transport.tokenizer = Tokenizer.new("\r\n")

    self[:volume_min] = 0
    self[:volume_max] = 255

    self[:power] = 0
    self[:stable_state] = true

    self[:type] = :projector
  end

  def on_update
  end

  def connected
    # Have to init comms
    send("ESC/VP.net\x10\x03\x00\x00\x00\x00")
    do_poll
    schedule.every(52.seconds) { do_poll }
  end

  def disconnected
    self[:power] = false
    schedule.clear

    @channel.close unless @channel.closed?
  end

  # used to coordinate the projector password hash
  @channel : Channel(String) = Channel(String).new

  #
  # Power commands
  #
  def power(state : Bool)
    self[:stable_state] = false
    if state
      self[:power_target] = true
      do_send(:PWR, true, timeout: 40000, name: :power)
      logger.debug { "-- epson Proj, requested to power on" }
      do_send(:PWR, name: :power_state)
    else
      self[:power_target] = false
      do_send(:PWR, false, timeout: 10000, name: :power)
      logger.debug { "-- epson Proj, requested to power off" }
      do_send(:PWR, name: :power_state)
    end
  end

  def power?(**options, &block)
    options[:emit] = block unless block.nil?
    options[:name] = :power_state
    do_send(:PWR, **options)
  end

  def switch_to(input : Input)
    do_send(:SOURCE, Input.from_value(input), name: :inpt_source)
    do_send(:SOURCE, name: :inpt_query)

    logger.debug { "-- epson LCD, requested to switch to: #{input}" }
    self[:input] = input # for a responsive UI
    self[:MUTE] = false
  end

  #
  # Volume commands are sent using the inpt command
  #
  def volume(vol : Int32, **options)
    vol = 0 if vol < 0
    vol = 255 if vol > 255

    # Seems to only return ":" for this command
    self[:volume] = vol
    self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
    do_send(:VOL, vol, **options)
  end

  # Mutes audio + video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "-- epson Proj, requested mute state: #{state}" }

    do_send(:MUTE, state, name: :video_mute) # Audio + Video
    do_send(:MUTE)                           # request status
  end

  def unmute(index : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    mute false, index, layer
  end

  # Audio mute
  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    mute state, index, MuteLayer::Audio

    val = state ? 0 : self[:unmute_volume]
    volume(val)
  end

  def unmute_audio(index : Int32 | String = 0)
    mute_audio(false, index)
  end

  def input?
    do_send(:SOURCE, name: :inpt_query, priority: 0)
  end

  enum ERROR
    "no error" = 00
    "fan error" = 01
    "lamp failure at power on" = 03
    "high internal temperature" = 04
    "lamp error" = 06
    "lamp cover door open" = 07
    "cinema filter error" = 08
    "capacitor is disconnected" = 09
    "auto iris error" = 0A
    "subsystem error" = 0B
    "low air flow error" = 0C
    "air flow sensor error" = 0D
    "ballast power supply error" = 0E
    "shutter error" = 0F
    "peltiert cooling error" = 10
    "pump cooling error" = 11
    "static iris error" = 12
    "power supply unit error" = 13
    "exhaust shutter error" = 14
    "obstacle detection error" = 15
    "IF board discernment error" = 16
end

  #
  # epson Response code
  #
  def received(data, resolve, command) # Data is default received as a string
    logger.debug { "epson Proj sent: #{data}" }

    if data == ":"
      return :success
    end

    data = data.split(/=|\r:/)
    case data[0].to_sym
    when :ERR
      # Lookup error!
      if data[1].nil?
        warning = "Epson PJ sent error response"
        warning << " for #{command[:data].inspect}" if command
        logger.warn { warning }
        return :abort
      else
        code = data[1].to_i(16)
        self[:last_error] = ERRORS[code] || "#{data[1]}: unknown error code #{code}"
        logger.warn { "Epson PJ error was #{self[:last_error]}" }
        return :success
      end
    when :PWR
      state = data[1].to_i
      self[:power] = state < 3
      self[:warming] = state == 2
      self[:cooling] = state == 3
      if self[:warming] || self[:cooling]
        schedule.in(5.seconds) { power?(priority: 0) }
      end
      if !self[:stable_state] && self[:power_target] == self[:power]
        self[:stable_state] = true
        self[:MUTE] = false if !self[:power]
      end
    when :MUTE
      self[:MUTE] = data[1] == true
    when :VOL
      vol = data[1].to_i
      self[:volume] = vol
      self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
    when :LAMP
      self[:lamp_usage] = data[1].to_i
    when :SOURCE
      self[:source] = INPUT_LOOKUP[data[1].to_i(16)] || :unknown
    end

    :success
  end

  def inspect_error
    do_send(:ERR, priority: 0)
  end

  protected def do_poll(*args)
    power?(priority: 0) do
      if self[:power]
        if self[:stable_state] == false && self[:power_target] == false
          power(false)
        else
          self[:stable_state] = true
          do_send(:SOURCE, name: :inpt_query, priority: 0)
          do_send(:MUTE, name: :MUTE_query, priority: 0)
          do_send(:VOL, name: :vol_query, priority: 0)
        end
      elsif self[:stable_state] == false
        if self[:power_target] == true
          power(true)
        else
          self[:stable_state] = true
        end
      end
    end
    do_send(:LAMP, priority: 0)
  end

  protected def do_send(command, param = nil, **options)
    # prepare the command
    cmd = if param.nil?
            "#{command}?\x0D"
          else
            "#{command} #{param}\x0D"
          end

    logger.debug { "queuing #{command}: #{cmd}" }

    # queue the request
    queue(**({
      name: command,
    }.merge(options))) do
      # prepare channel and connect to the projector (which will then send the random key)
      @channel = Channel(String).new
      transport.connect

      message = cmd
      logger.debug { "Sending: #{message}" }

      # send the request
      # NOTE:: the built in `send` function has implicit queuing, but we are
      # in a task callback here so should be calling transport send directly
      transport.send(message)
    end
  end
end
