require "placeos-driver"
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

  include Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 3629
  descriptive_name "Epson Projector"
  generic_name :Display

  @power_stable : Bool = true
  @power_target : Bool = true
  @unmute_volume : Float64 = 60.0

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
  end

  def power(state : Bool)
    if state
      @power_target = true
      logger.debug { "-- epson Proj, requested to power on" }
      do_send(:power, "ON", delay: 40.seconds, name: "power")
    else
      @power_target = false
      logger.debug { "-- epson Proj, requested to power off" }
      do_send(:power, "OFF", delay: 10.seconds, name: "power")
    end
    @power_stable = false
    power?
  end

  def power?(**options) : Bool
    do_send(:power, **options).get
    !!self[:power]?.try(&.as_bool)
  end

  def switch_to(input : Input)
    logger.debug { "-- epson Proj, requested to switch to: #{input}" }
    do_send(:input, input.value.to_s(16), name: :input)

    # for a responsive UI
    self[:input] = input # for a responsive UI
    self[:video_mute] = false
    input?
  end

  def input?
    do_send(:input, priority: 0).get
    self[:input]
  end

  # Volume commands are sent using the inpt command
  def volume(vol : Float64 | Int32, **options)
    vol = vol.to_f.clamp(0.0, 100.0)
    percentage = vol / 100.0
    vol_actual = (percentage * 255.0).round_away.to_i

    @unmute_volume = self[:volume].as_f if (mute = vol == 0.0) && self[:volume]?
    do_send(:volume, vol_actual, **options, name: :volume)

    # for a responsive UI
    self[:volume] = vol
    self[:audio_mute] = mute
    volume?
  end

  def volume?
    do_send(:volume, priority: 0).get
    self[:volume]?.try(&.as_f)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    case layer
    when .audio_video?
      do_send(:av_mute, state ? "ON" : "OFF", name: :mute)
      do_send(:av_mute, name: :mute?, priority: 0)
    when .video?
      do_send(:video_mute, state ? "ON" : "OFF", name: :video_mute)
      video_mute?
    when .audio?
      val = state ? 0.0 : @unmute_volume
      volume(val)
    end
  end

  def video_mute?
    do_send(:video_mute, priority: 0).get
    !!self[:video_mute]?.try(&.as_bool)
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
    "16: IF board discernment error",
  ]

  def inspect_error
    do_send(:error, priority: 0)
  end

  COMMAND = {
    power:      "PWR",
    input:      "SOURCE",
    volume:     "VOL",
    av_mute:    "MUTE",
    video_mute: "MSEL",
    error:      "ERR",
    lamp:       "LAMP",
  }
  RESPONSE = COMMAND.to_h.invert

  def received(data, task)
    return task.try(&.success) if data.size <= 2
    data = String.new(data[1..-2])
    logger.debug { "epson Proj sent: #{data}" }

    data = data.split('=')
    case RESPONSE[data[0]]
    when :error
      if data[1]?
        code = data[1].to_i(16)
        self[:last_error] = ERRORS[code]? || "#{data[1]}: unknown error code #{code}"
        return task.try(&.success("Epson PJ error was #{self[:last_error]}"))
      else # Lookup error!
        return task.try(&.abort("Epson PJ sent error response for #{task.not_nil!.name || "unknown"}"))
      end
    when :power
      state = data[1].to_i
      self[:power] = powered = state < 3
      self[:warming] = warming = state == 2
      self[:cooling] = cooling = state == 3

      if warming || cooling
        schedule.in(5.seconds) { power?(priority: 0) }
      end

      if powered == @power_target
        self[:video_mute] = false unless powered
      end
    when :av_mute
      self[:video_mute] = self[:audio_mute] = data[1] == "ON"
      self[:volume] = 0.0
    when :video_mute
      self[:video_mute] = data[1] == "ON"
    when :volume
      # convert to a percentage
      vol = data[1].to_i
      vol_percent = (vol.to_f / 255.0) * 100.0
      self[:volume] = vol_percent

      mute = vol == 0
      self[:audio_mute] = mute if mute
      @unmute_volume ||= vol_percent unless mute
    when :lamp
      self[:lamp_usage] = data[1].to_i
    when :input
      self[:input] = Input.from_value(data[1].to_i(16)) || "unknown"
    end

    task.try(&.success)
  end

  def do_poll
    if power?(priority: 0)
      if !@power_stable
        if self[:power]? == @power_target
          @power_stable = true
        else
          power(@power_target)
        end
      else
        input?
        video_mute?
        volume?
      end
    end
    do_send(:lamp, priority: 0)
  end

  private def do_send(command, param = nil, **options)
    command = COMMAND[command]
    cmd = param ? "#{command} #{param}\r" : "#{command}?\r"
    logger.debug { "Epson proj sending #{command}: #{cmd}" }
    send(cmd, **options)
  end
end
