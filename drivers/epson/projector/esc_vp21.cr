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

  @power_target : Bool? = nil

  def on_load
    transport.tokenizer = Tokenizer.new("\r")
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
    power?
  end

  def power?(**options) : Bool
    do_send(:PWR, **options, name: :power?).get
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

  def volume?
    do_send(:VOL, name: :volume?, priority: 0)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "-- epson Proj, requested mute state: #{state}" }

    # Video mute
    if layer.video? || layer.audio_video?
      do_send(:MUTE, state, name: :video_mute)
      video_mute?
    end

    mute_audio if layer.audio? || layer.audio_video?
  end

  def mute_audio(state : Bool = true)
    val = state ? 0 : self[:unmute_volume].as_i
    volume(val)
  end

  def video_mute?
    do_send(:MUTE, name: :video_mute?, priority: 0).get
    !!self[:video_mute]?.try(&.as_bool)
  end

  def input?
    do_send(:SOURCE, name: :input_query, priority: 0).get
    self[:input]
  end

  ERRORS = [
    "00: no error",
    "01: fan error",
    "03: lamp failure at power on",
    "04: high internal temperature",
    "06: lamp error",
    "07: lamp cover door open",
    "08: cinema filter error",
    "09: capacitor is disconnected",
    "0A: auto iris error",
    "0B: subsystem error",
    "0C: low air flow error",
    "0D: air flow sensor error",
    "0E: ballast power supply error",
    "0F: shutter error",
    "10: peltiert cooling error",
    "11: pump cooling error",
    "12: static iris error",
    "13: power supply unit error",
    "14: exhaust shutter error",
    "15: obstacle detection error",
    "16: IF board discernment error"
  ]

  def received(data, task)
    data = String.new(data[0..-2])
    logger.debug { "epson Proj sent: #{data}" }

    if data == ":"
      return task.try(&.success)
    end

    data = data.split(/=|\r:/)
    case data[0]
    when ":ERR"
      # Lookup error!
      if data[1]?
        code = data[1].to_i(16)
        self[:last_error] = ERRORS[code]? || "#{data[1]}: unknown error code #{code}"
        return task.try(&.success("Epson PJ error was #{self[:last_error]}"))
      else
        return task.try(&.abort("Epson PJ sent error response for #{task.not_nil!.name || "unknown"}"))
      end
    when ":PWR"
      state = data[1].to_i
      self[:power] = state < 3
      self[:warming] = state == 2
      self[:cooling] = state == 3

      if self[:warming].as_bool || self[:cooling].as_bool
        schedule.in(5.seconds) { power?(priority: 0) }
      end

      if (power_target = @power_target) && self[:power] == power_target
        @power_target = nil
        self[:video_mute] = false unless self[:power].as_bool
      end
    when ":MUTE"
      self[:video_mute] = data[1] == true
    when ":VOL"
      vol = data[1].to_i
      self[:volume] = vol
      self[:unmute_volume] = vol if vol > 0 # Store the "pre mute" volume, so it can be restored on unmute
    when ":LAMP"
      self[:lamp_usage] = data[1].to_i
    when ":SOURCE"
      self[:input] = Input.from_value(data[1].to_i(16)) || :unknown
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
        input?
        video_mute?
        volume?
      end
    end
    do_send(:LAMP, priority: 0)
  end

  private def do_send(command, param = nil, **options)
    cmd = param ? "#{command} #{param}\r" : "#{command}?\r"
    logger.debug { "Epson proj sending #{command}: #{cmd}" }
    send(cmd, **options)
  end
end
