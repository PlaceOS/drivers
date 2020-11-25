require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Epson::Projector::EscVp21 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    HDMI    = 0x30
    HDBaseT = 0x80
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 3629
  descriptive_name "Epson Projector"
  generic_name :Display

  enum Error
    None                    =  0x9
    Fan                     =  0x1
    LampAtPowerOn           =  0x3
    HighInternalTemperature =  0x4
    Lamp                    =  0x6
    LampCoverDoorOpen       =  0x7
    CinemaFilter            =  0x8
    CapacitorDisconnected   =  0x9
    AutoIris                =  0xA
    Subsystem               =  0xB
    LowAirFlow              =  0xC
    AirFlowSensor           =  0xD
    BallastPowerSupply      =  0xE
    Shutter                 =  0xF
    PeltiertCooling         = 0x10
    PumpCooling             = 0x11
    StaticIris              = 0x12
    PowerSupplyUnit         = 0x13
    ExhaustShutter          = 0x14
    ObstacleDetection       = 0x15
    BoardDiscernment        = 0x16
  end

  @power_target : Bool? = nil

  def on_load
    transport.tokenizer = Tokenizer.new("\r\n")
    self[:type] = :projector
  end

  def connected
    # Have to init comms
    send("ESC/VP.net\x10\x03\x00\x00\x00\x00")
    schedule.every(52.seconds, true) { do_poll }
  end

  def disconnected
    schedule.clear
    self[:power] = false
  end

  # Power commands
  def power(state : Bool)
    if state
      @power_target = true
      logger.debug { "-- epson Proj, requested to power on" }
      do_send(:PWR, :ON, delay: 40.seconds, name: "power")
    else
      @power_target = false
      logger.debug { "-- epson Proj, requested to power off" }
      do_send(:PWR, :OFF, delay: 10.seconds, name: "power")
    end
    do_send(:PWR, name: :power_state)
  end

  def power?(**options) : Bool
    do_send(:PWR, **options, name: :power?)#.get
    !!self[:power]?.try(&.as_bool)
  end

  def switch_to(input : Input)
    logger.debug { "-- epson Proj, requested to switch to: #{input}" }
    do_send(:SOURCE, input.value, name: :input_source)
    do_send(:SOURCE, name: :input_query)
    self[:input] = input # for a responsive UI
    self[:mute] = false
  end

  # Volume commands are sent using the inpt command
  def volume(vol : Int32, **options)
    vol = vol.clamp(0, 255)
    do_send(:VOL, vol, **options, name: :volume)
    self[:volume] = vol
    self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
  end

  # Mutes audio + video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "-- epson Proj, requested mute state: #{state}" }

    # Video mute
    if layer.video? || layer.audio_video?
      do_send(:MUTE, state, name: :video_mute)
      do_send(:MUTE) # request status
    end

    mute_audio if layer.audio? || layer.audio_video?
  end

  # Audio mute
  def mute_audio(state : Bool = true)
    val = state ? 0 : self[:unmute_volume].as_i
    volume(val)
  end

  def input?
    do_send(:SOURCE, name: :input_query, priority: 0)
  end

  def received(data, task)
    logger.debug { "epson Proj sent: #{data}" }

    if data == ":"
      return task.try(&.success)
    end

    data = String.new(data).split(/=|\r:/)
    case data[0]
    when :ERR
      # Lookup error!
      if data[1].nil?
        warning = "Epson PJ sent error response"
        # warning << " for #{command[:data].inspect}" if command
        return task.try(&.abort(warning))
      else
        code = data[1].to_i(16)
        self[:last_error] = Error.from_value(code) || "#{data[1]}: unknown error code #{code}"
        return task.try(&.success("Epson PJ error was #{self[:last_error]}"))
      end
    when :PWR
      state = data[1].to_i
      self[:power] = state < 3
      self[:warming] = state == 2
      self[:cooling] = state == 3

      if self[:warming] || self[:cooling]
        schedule.in(5.seconds) { power?(priority: 0) }
      end

      if (power_target = @power_target) && self[:power] == power_target
        @power_target = nil
        self[:mute] = false unless power_target
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
      self[:source] = Input.from_value(data[1].to_i(16)) || :unknown
    end

    task.try(&.success)
  end

  def inspect_error
    do_send(:ERR, priority: 0)
  end

  def do_poll
    if power?(priority: 0)
      if power_target = @power_target
        if self[:power] != power_target
          power(power_target)
        else
          @power_target = nil
        end
      else
        do_send(:SOURCE, name: :input_query, priority: 0)
        do_send(:MUTE, name: :mute_query, priority: 0)
        do_send(:VOL, name: :volume_query, priority: 0)
      end
    end

    do_send(:LAMP, priority: 0)
  end

  private def do_send(command : Symbol, param = nil, **options)
    cmd = param ? "#{command} #{param}\x0D" : "#{command}?\x0D"
    logger.debug { "Epson proj sending #{command}: #{cmd}" }
    send(cmd, **options)
  end
end
