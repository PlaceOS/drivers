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
  description <<-DESC
    ESC/VP.net control. If a Web Control / Monitor password is configured on the projector,
    set the `password` setting (printable ASCII, max 16 characters).
    Protocol: ESC/VP.net Software Development Manual (CONNECT request, Password header)
    DESC

  default_settings({
    password: "",
  })

  @ready : Bool = false
  @password : String = ""
  @connect_rejected : Bool = false

  getter power_actual : Bool? = nil  # actual power state
  getter? power_stable : Bool = true # are we in a stable state?
  getter? power_target : Bool = true # what is the target state?

  @unmute_volume : Float64 = 60.0

  def on_load
    self[:type] = :projector
    on_update
  end

  def on_update
    password = setting?(String, :password) || ""
    if password.bytesize > 16
      logger.warn { "ESC/VP.net passwords are limited to 16 characters, truncating" }
      password = password.byte_slice(0, 16)
    end

    # the password is only sent as part of the connection handshake
    changed = password != @password
    @password = password
    return unless changed

    # reconnect to handshake with the new password, skipping any back-off
    disconnect if @ready || @connect_rejected
    @connect_rejected = false
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

    # Have to init comms, backing off after a rejection so we don't hammer the projector
    if @connect_rejected
      schedule.in(10.seconds) { send(connect_request, priority: 99) }
    else
      send(connect_request, priority: 99)
    end
  end

  def disconnected
    transport.tokenizer = nil
    schedule.clear

    # ESC/VP21 commands are only valid after the CONNECT handshake
    @ready = false
    self[:ready] = false
    queue.clear abort_current: true
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

  # ESC/VP.net header: identifier, version 0x10, type 0x03 (CONNECT), reserved (2 bytes), status 0x00
  CONNECT_HEADER = "ESC/VP.net\x10\x03\x00\x00\x00"

  enum ConnectStatus : UInt8
    OK                  = 0x20
    BadRequest          = 0x40
    Unauthorized        = 0x41 # password required
    Forbidden           = 0x43 # password is wrong
    RequestNotAllowed   = 0x45
    ServiceUnavailable  = 0x53 # projector busy
    VersionNotSupported = 0x55
  end

  protected def connect_request : Bytes
    io = IO::Memory.new
    io << CONNECT_HEADER
    if @password.empty?
      io.write_byte 0_u8 # number of headers
    else
      io.write_byte 1_u8 # number of headers
      io.write_byte 1_u8 # header identifier: Password
      io.write_byte 1_u8 # attribute: Plain
      password = @password.to_slice
      io.write password
      (16 - password.size).times { io.write_byte 0_u8 }
    end
    io.to_slice
  end

  def received(data, task)
    return handle_connect_response(data, task) unless @ready

    data = String.new(data)
    logger.debug { "<< Received from Epson Proj: #{data.inspect}" }

    # cleanup the data
    data = data.strip.strip(':').strip

    # projector returns ":" on success
    return task.try(&.success) if data.size <= 2

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

  private def handle_connect_response(data : Bytes, task)
    logger.debug { "<< Received from Epson Proj: #{String.new(data).inspect}" }
    return task.try(&.success) unless String.new(data).includes?("ESC/VP.net")

    # byte 14 is the status code of the CONNECT response
    if (byte = data[14]?) && byte != ConnectStatus::OK.value
      status = ConnectStatus.from_value?(byte)
      message = case status
                when .nil?          then "projector rejected the connection: status 0x#{byte.to_s(16)}"
                when .unauthorized? then "projector requires a password, please configure the password setting"
                when .forbidden?    then "projector rejected the configured password"
                else                     "projector rejected the connection: #{status}"
                end
      logger.error { "Epson #{message}" }
      self[:connect_error] = message
      @connect_rejected = true
      task.try(&.abort(message))
      # projector closes the connection after an error response
      disconnect
      return
    end

    logger.debug { "-- Epson projector ready to accept commands" }
    transport.tokenizer = Tokenizer.new(":")
    @ready = true
    @connect_rejected = false
    self[:ready] = true
    self[:connect_error] = nil
    task.try(&.success)

    # poll outside the IO fiber, it waits on responses
    schedule.every(52.seconds) { do_poll }
    spawn { do_poll }
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
    # the projector only accepts ESC/VP21 commands after a successful CONNECT handshake
    raise "Epson projector session not established" unless @ready

    command = COMMAND[command]
    cmd = param ? "#{command} #{param}\r" : "#{command}?\r"
    logger.debug { ">> Sending to Epson Proj - #{command}: #{cmd}" }
    send(cmd, **options)
  end
end
