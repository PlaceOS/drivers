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

  enum Inputs
    HDMI
    HDBaseT
  end

  # Discovery Information
  tcp_port 1024
  descriptive_name "Epson Projectors"
  generic_name :Display

  def on_load
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
  end

  #
  # Power commands
  #
  def power(state : Bool, opt = nil)
    self[:stable_state] = false
    if state
      self[:power_target] = true
      do_send(:PWR, :ON, {:timeout => 40000, :name => :power})
      logger.debug { "-- epson Proj, requested to power on" }
      do_send(:PWR, {:name => :power_state})
    else
      self[:power_target] = false
      do_send(:PWR, :OFF, {:timeout => 10000, :name => :power})
      logger.debug { "-- epson Proj, requested to power off" }
      do_send(:PWR, {:name => :power_state})
    end
  end

  def power?(**options, &block)
    options[:emit] = block unless block.nil?
    options[:name] = :power_state
    do_send(:PWR, **options)
  end

  #
  # Input selection
  #
  INPUTS = {
    Inputs::HDMI    => 0x30,
    Inputs::HDBaseT => 0x80,
  }
  INPUT_LOOKUP = INPUTS.invert

  def switch_to(input : Inputs)
    do_send(:SOURCE, INPUTS[input], name: :inpt_source)
    do_send(:SOURCE, name: :inpt_query)

    logger.debug { "-- epson LCD, requested to switch to: #{input}" }
    self[:input] = input # for a responsive UI
    self[:mute] = false
  end

  #
  # Volume commands are sent using the inpt command
  #
  def volume(vol, **options)
    vol = vol.to_i
    vol = 0 if vol < 0
    vol = 255 if vol > 255

    # Seems to only return ":" for this command
    self[:volume] = vol
    self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
    do_send(:VOL, vol, **options)
  end

  #
  # Mute Audio and Video
  #
  def mute(state : Bool)
    logger.debug { "-- epson Proj, requested to mute #{state}" }
    do_send(:MUTE, state, name: :video_mute) # Audio + Video
    do_send(:MUTE)                           # request status
  end

  def unmute
    mute(false)
  end

  # Audio mute
  def mute_audio(state : Bool = true)
    val = state ? 0 : self[:unmute_volume]
    volume(val)
  end

  def unmute_audio
    mute_audio(false)
  end

  def input?
    do_send(:SOURCE, {
      :name     => :inpt_query,
      :priority => 0,
    })
  end

  ERRORS = {
     0 => "00: no error",
     1 => "01: fan error",
     3 => "03: lamp failure at power on",
     4 => "04: high internal temperature",
     6 => "06: lamp error",
     7 => "07: lamp cover door open",
     8 => "08: cinema filter error",
     9 => "09: capacitor is disconnected",
    10 => "0A: auto iris error",
    11 => "0B: subsystem error",
    12 => "0C: low air flow error",
    13 => "0D: air flow sensor error",
    14 => "0E: ballast power supply error",
    15 => "0F: shutter error",
    16 => "10: peltiert cooling error",
    17 => "11: pump cooling error",
    18 => "12: static iris error",
    19 => "13: power supply unit error",
    20 => "14: exhaust shutter error",
    21 => "15: obstacle detection error",
    22 => "16: IF board discernment error",
  }

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
        schedule.in("5s") do
          power?({:priority => 0})
        end
      end
      if !self[:stable_state] && self[:power_target] == self[:power]
        self[:stable_state] = true
        self[:mute] = false if !self[:power]
      end
    when :MUTE
      self[:mute] = data[1] == true
    when :VOL
      vol = data[1].to_i
      self[:volume] = vol
      self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
    when :LAMP
      self[:lamp_usage] = data[1].to_i
    when :SOURCE
      self[:source] = INPUTS[data[1].to_i(16)] || :unknown
    end

    :success
  end

  def inspect_error
    do_send(:ERR, priority: 0)
  end

  protected def do_poll(*args)
    power?({:priority => 0}) do
      if self[:power]
        if self[:stable_state] == false && self[:power_target] == false
          power(false)
        else
          self[:stable_state] = true
          do_send(:SOURCE, {
            :name     => :inpt_query,
            :priority => 0,
          })
          do_send(:MUTE, {
            :name     => :mute_query,
            :priority => 0,
          })
          do_send(:VOL, {
            :name     => :vol_query,
            :priority => 0,
          })
        end
      elsif self[:stable_state] == false
        if self[:power_target] == true
          power(true)
        else
          self[:stable_state] = true
        end
      end
    end
    do_send(:LAMP, {:priority => 0})
  end

  protected def do_send(command, param = nil, **options)
    if param.is_a? Hash
      options = param
      param = nil
    end

    if param.nil?
      send("#{command}?\x0D", **options)
    else
      send("#{command} #{param}\x0D", **options)
    end
  end
end
