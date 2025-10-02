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

  @ready : Bool = false

  getter power_actual : Bool? = nil  # actual power state
  getter? power_stable : Bool = true # are we in a stable state?
  getter? power_target : Bool = true # what is the target state?

  @unmute_volume : Float64 = 60.0

  def on_load
    self[:type] = :projector
  end

  def connected
    @ready = false
    self[:ready] = false

    schedule.in(20.seconds) do
      if !@ready
        logger.error { "Epson failed to be ready after 20 seconds. Reconnecting..." }
        disconnect
      end
    end

    # Have to init comms
    send("ESC/VP.net\x10\x03\x00\x00\x00\x00", priority: 99)
    schedule.every(52.seconds, true) { do_poll }
  end

  def disconnected
    transport.tokenizer = nil
    schedule.clear
  end

  def power(state : Bool)
    if state
      @power_target = true
      logger.debug { "-- epson Proj, requested to power on" }
      do_send(:power, "ON", timeout: 110.seconds, delay: 5.seconds, name: "power", priority: 99)
    else
      @power_target = false
      logger.debug { "-- epson Proj, requested to power off" }
      do_send(:power, "OFF", timeout: 140.seconds, delay: 5.seconds, name: "power", priority: 99)
    end
    @power_stable = false
    self[:power] = state
    power?
  end

  def power?(priority : Int32 = 50) : Bool
    do_send(:power, priority: priority).get
    @power_target || false
  end

  def switch_to(input : Input)
    logger.debug { "-- epson Proj, requested to switch to: #{input}" }
    mute(false, layer: MuteLayer::Video)
    do_send(:input, input.value.to_s(16), name: :input, timeout: 6.seconds, delay: 1.second)

    # for a responsive UI
    self[:input] = input # for a responsive UI
    self[:video_mute] = false
    input?
  end

  def input?
    do_send(:input, priority: 0)
    self[:input]?.try(&.as_s?)
  end

  # Volume commands are sent using the inpt command
  def volume(vol : Float64 | Int32, **options)
    vol = vol.to_f.clamp(0.0, 100.0)
    percentage = vol / 100.0
    vol_actual = (percentage * 255.0).round_away.to_i

    @unmute_volume = self[:volume].as_f if (muted = vol.zero?) && self[:volume]?
    do_send(:volume, vol_actual, **options, name: :volume)

    # for a responsive UI
    self[:volume] = vol
    self[:audio_mute] = muted
    volume?
  end

  def volume?
    do_send(:volume, priority: 0)
    self[:volume]?.try(&.as_f)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    case layer
    when .video?, .audio_video?
      do_send(:av_mute, state ? "ON" : "OFF", name: :mute)
      video_mute?
    when .audio?
      val = state ? 0.0 : @unmute_volume
      volume(val)
    end
  end

  def video_mute?
    do_send(:av_mute, priority: 0)
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
    "17: Communication error of 'Stack projection function'",
    "18: I2C error",
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
    data = String.new(data)
    logger.debug { "<< Received from Epson Proj: #{data.inspect}" }

    # cleanup the data
    data = data.strip.strip(':').strip

    # projector returns ":" on success
    return task.try(&.success) if data.size <= 2

    if !@ready
      if data.includes?("ESC/VP.net")
        logger.debug { "-- Epson projector ready to accept commands" }
        transport.tokenizer = Tokenizer.new(":")
        @ready = true
        self[:ready] = true
      end
      return task.try(&.success)
    end

    # Handle IMEVENT messages
    if data.starts_with?("IMEVENT=")
      parse_imevent(data)
      return task.try(&.success)
    end

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
      @power_actual = powered = state < 3
      warming = state == 2
      cooling = state == 3

      if warming || cooling
        schedule.in(5.seconds) { power?(priority: 10) }
      elsif !@power_stable
        if @power_actual == @power_target
          @power_stable = true
        else
          power(@power_target)
        end
      end

      self[:power] = powered if @power_stable
      self[:warming] = warming
      self[:cooling] = cooling

      if powered == @power_target
        self[:video_mute] = false unless powered
      end
    when :av_mute
      self[:video_mute] = data[1] == "ON"
    when :video_mute
      # we don't use this command
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
      self[:lamp_usage] = data[1].split(" ")[0].to_i # split added as we see responses like "LAMP=1633 1633"
    when :input
      self[:input] = Input.from_value(data[1].to_i(16)) || "unknown"
    end

    task.try(&.success)
  end

  def do_poll
    if power?(priority: 20) && @power_stable
      input?
      volume?
      video_mute?
    end
    do_send(:lamp, priority: 20)
  end

  private def parse_imevent(data : String)
    # IMEVENT format: IMEVENT=0001 03 00000000 00000000 T1 F1
    parts = data.split(' ')
    return unless parts.size >= 6

    begin
      # Extract status code from second part
      status_code = parts[1].to_i(16)

      # Map status code to power state
      power_state = case status_code
                    when 1 then false # STATE_OFF
                    when 2 then false # STATE_WARMUP
                    when 3 then true  # STATE_ON
                    when 4 then false # STATE_COOLDOWN
                    else
                      nil
                    end

      if !power_state.nil?
        @power_actual = power_state

        # Determine if warming/cooling based on status code
        warming = status_code == 2
        cooling = status_code == 4

        if warming || cooling
          schedule.in(5.seconds) { power?(priority: 10) }
        elsif !@power_stable
          if @power_actual == @power_target
            @power_stable = true
          else
            power(@power_target)
          end
        end

        self[:power] = power_state if @power_stable
        self[:warming] = warming
        self[:cooling] = cooling

        if power_state == @power_target
          self[:video_mute] = false unless power_state
        end
      end

      # Parse warning bits (parts[2])
      warning_bits = parts[2].to_u32(16)
      active_warnings = [] of String
      warning_map = {0 => "Lamp life", 1 => "No signal", 2 => "Unsupported signal", 3 => "Air filter", 4 => "High temperature"}
      warning_map.each do |bit, description|
        if (warning_bits >> bit) & 1 == 1
          active_warnings << description
        end
      end
      self[:warnings] = active_warnings

      # Parse alarm bits (parts[3])
      alarm_bits = parts[3].to_u32(16)
      active_alarms = [] of String
      alarm_map = {0 => "Lamp ON failure", 1 => "Lamp lid", 2 => "Lamp burnout", 3 => "Fan", 4 => "Temperature sensor", 5 => "High temperature", 6 => "Interior (system)"}
      alarm_map.each do |bit, description|
        if (alarm_bits >> bit) & 1 == 1
          active_alarms << description
        end
      end
      self[:alarms] = active_alarms

      logger.debug { "IMEVENT parsed - Power: #{power_state}, Warnings: #{active_warnings}, Alarms: #{active_alarms}" }
    rescue ex
      logger.warn(exception: ex) { "Failed to parse IMEVENT: #{data}" }
    end
  end

  private def do_send(command, param = nil, **options)
    command = COMMAND[command]
    cmd = param ? "#{command} #{param}\r" : "#{command}?\r"
    logger.debug { ">> Sending to Epson Proj - #{command}: #{cmd}" }
    send(cmd, **options)
  end
end
