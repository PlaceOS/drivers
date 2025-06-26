require "placeos-driver"
require "placeos-driver/interface/muteable"

class Sennheiser::TCC2SSCv1 < PlaceOS::Driver
  include Interface::AudioMuteable

  descriptive_name "Sennheiser TCC2 Microphone (SSCv1)"
  generic_name :TCC2
  description "Driver for Sennheiser TCC2 TeamConnect Ceiling Microphone using Sound Control Protocol v1 (SSCV1). Uses UDP port 45 with JSON messages following exact protocol specification."

  udp_port 45

  default_settings({
    poll_interval: 30, # seconds
  })

  @poll_interval : Int32 = 30

  def on_load
    on_update
  end

  def on_update
    @poll_interval = setting?(Int32, :poll_interval) || 30
  end

  def connected
    # Get protocol version first
    get_osc_version
    # Get initial device state
    get_device_identity
    get_audio_mute_status

    # Schedule periodic status polling
    schedule.every(@poll_interval.seconds, immediate: true) do
      query_device_status
    end
  end

  def disconnected
    schedule.clear
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    begin
      # Parse JSON response
      message = JSON.parse(data)

      if task
        # Handle response to a specific request
        handle_response(message, task)
      else
        # Handle unsolicited messages (status updates, notifications)
        handle_notification(message)
      end
    rescue e : JSON::ParseException
      logger.warn { "Failed to parse JSON: #{e.message}" }
      task.try(&.abort("Invalid JSON response"))
    end
  end

  # === Interface::AudioMuteable Implementation ===

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    set_mute(state)
  end

  # === OSC Protocol Methods ===

  def get_osc_version
    message = {"osc" => {"version" => nil}}
    send_command(message)
  end

  def get_osc_ping
    message = {"osc" => {"ping" => nil}}
    send_command(message)
  end

  # === Audio Control Methods (following exact SSCV1 protocol) ===

  def set_mute(muted : Bool)
    message = {"audio" => {"mute" => muted}}
    send_command(message, name: "mute")
  end

  def get_audio_mute_status
    message = {"audio" => {"mute" => nil}}
    send_command(message)
  end

  def get_audio_room_in_use
    message = {"audio" => {"room_in_use" => nil}}
    send_command(message)
  end

  def set_audio_installation_type(type : String)
    # Valid options: "flush_mount", "suspended"
    unless ["flush_mount", "suspended"].includes?(type)
      raise ArgumentError.new("Invalid installation type: #{type}")
    end
    message = {"audio" => {"installation_type" => type}}
    send_command(message, name: "installation_type")
  end

  def get_audio_installation_type
    message = {"audio" => {"installation_type" => nil}}
    send_command(message)
  end

  # === Audio Output Controls ===

  def set_audio_out1_attenuation(level : Int32)
    # Range: -18 to 0 dB
    clamped_level = level.clamp(-18, 0)
    message = {"audio" => {"out1" => {"attenuation" => clamped_level}}}
    send_command(message, name: "out1_attenuation")
  end

  def get_audio_out1_attenuation
    message = {"audio" => {"out1" => {"attenuation" => nil}}}
    send_command(message)
  end

  def set_audio_out2_gain(level : Int32)
    # Range: 0 to 24 dB (Dante output)
    clamped_level = level.clamp(0, 24)
    message = {"audio" => {"out2" => {"gain" => clamped_level}}}
    send_command(message, name: "out2_gain")
  end

  def get_audio_out2_gain
    message = {"audio" => {"out2" => {"gain" => nil}}}
    send_command(message)
  end

  # === Audio Reference Controls ===

  def set_audio_ref1_gain(level : Int32)
    # Range: -60 to 10 dB (AEC Reference gain)
    clamped_level = level.clamp(-60, 10)
    message = {"audio" => {"ref1" => {"gain" => clamped_level}}}
    send_command(message, name: "ref1_gain")
  end

  def get_audio_ref1_gain
    message = {"audio" => {"ref1" => {"gain" => nil}}}
    send_command(message)
  end

  def set_audio_ref1_farend_auto_adjust(enable : Bool)
    message = {"audio" => {"ref1" => {"farend_auto_adjust_enable" => enable}}}
    send_command(message, name: "farend_auto_adjust")
  end

  def get_audio_ref1_farend_auto_adjust
    message = {"audio" => {"ref1" => {"farend_auto_adjust_enable" => nil}}}
    send_command(message)
  end

  # === Metering Methods ===

  def get_meter_beam_elevation
    message = {"m" => {"beam" => {"elevation" => nil}}}
    send_command(message)
  end

  def get_meter_beam_azimuth
    message = {"m" => {"beam" => {"azimuth" => nil}}}
    send_command(message)
  end

  def get_meter_input_peak
    message = {"m" => {"in1" => {"peak" => nil}}}
    send_command(message)
  end

  def get_meter_ref1_rms
    message = {"m" => {"ref1" => {"rms" => nil}}}
    send_command(message)
  end

  # === Device Control Methods ===

  def set_device_identification_visual(enable : Bool)
    message = {"device" => {"identification" => {"visual" => enable}}}
    send_command(message, name: "identification")
  end

  def get_device_identification_visual
    message = {"device" => {"identification" => {"visual" => nil}}}
    send_command(message)
  end

  def get_device_identity
    # Get all device identity information
    get_device_identity_version
    get_device_identity_vendor
    get_device_identity_product
    get_device_identity_serial
    get_device_identity_hw_revision
  end

  def get_device_identity_version
    message = {"device" => {"identity" => {"version" => nil}}}
    send_command(message)
  end

  def get_device_identity_vendor
    message = {"device" => {"identity" => {"vendor" => nil}}}
    send_command(message)
  end

  def get_device_identity_product
    message = {"device" => {"identity" => {"product" => nil}}}
    send_command(message)
  end

  def get_device_identity_serial
    message = {"device" => {"identity" => {"serial" => nil}}}
    send_command(message)
  end

  def get_device_identity_hw_revision
    message = {"device" => {"identity" => {"hw_revision" => nil}}}
    send_command(message)
  end

  def set_device_name(name : String)
    # Name must be 8 chars max, start with letter, end with letter/digit
    if name.size > 8
      raise ArgumentError.new("Device name must be 8 characters or less")
    end
    message = {"device" => {"name" => name}}
    send_command(message, name: "device_name")
  end

  def get_device_name
    message = {"device" => {"name" => nil}}
    send_command(message)
  end

  def set_device_location(location : String)
    # Max 100 characters
    if location.size > 100
      raise ArgumentError.new("Device location must be 100 characters or less")
    end
    message = {"device" => {"location" => location}}
    send_command(message, name: "device_location")
  end

  def get_device_location
    message = {"device" => {"location" => nil}}
    send_command(message)
  end

  def set_device_position(position : String)
    # Max 30 characters
    if position.size > 30
      raise ArgumentError.new("Device position must be 30 characters or less")
    end
    message = {"device" => {"position" => position}}
    send_command(message, name: "device_position")
  end

  def get_device_position
    message = {"device" => {"position" => nil}}
    send_command(message)
  end

  def device_restart
    message = {"device" => {"restart" => true}}
    send_command(message, name: "restart")
  end

  def device_restore(type : String)
    # Valid options: "FACTORY_DEFAULTS", "AUDIO_DEFAULTS", "DANTE_FACTORY_DEFAULTS"
    valid_types = ["FACTORY_DEFAULTS", "AUDIO_DEFAULTS", "DANTE_FACTORY_DEFAULTS"]
    unless valid_types.includes?(type)
      raise ArgumentError.new("Invalid restore type: #{type}")
    end
    message = {"device" => {"restore" => type}}
    send_command(message, name: "restore")
  end

  # === LED Control Methods ===

  def set_device_led_brightness(level : Int32)
    # Range: 0 to 5 (6 steps, 0 = off)
    clamped_level = level.clamp(0, 5)
    message = {"device" => {"led" => {"brightness" => clamped_level}}}
    send_command(message, name: "led_brightness")
  end

  def get_device_led_brightness
    message = {"device" => {"led" => {"brightness" => nil}}}
    send_command(message)
  end

  def set_device_led_custom_color(color : String)
    # Valid colors: LIGHT_GREEN, GREEN, BLUE, RED, YELLOW, ORANGE, CYAN, PINK
    valid_colors = ["LIGHT_GREEN", "GREEN", "BLUE", "RED", "YELLOW", "ORANGE", "CYAN", "PINK"]
    unless valid_colors.includes?(color)
      raise ArgumentError.new("Invalid LED color: #{color}")
    end
    message = {"device" => {"led" => {"custom" => {"color" => color}}}}
    send_command(message, name: "led_custom_color")
  end

  def get_device_led_custom_color
    message = {"device" => {"led" => {"custom" => {"color" => nil}}}}
    send_command(message)
  end

  def set_device_led_custom_active(enable : Bool)
    message = {"device" => {"led" => {"custom" => {"active" => enable}}}}
    send_command(message, name: "led_custom_active")
  end

  def get_device_led_custom_active
    message = {"device" => {"led" => {"custom" => {"active" => nil}}}}
    send_command(message)
  end

  def set_device_led_mic_mute_color(color : String)
    valid_colors = ["LIGHT_GREEN", "GREEN", "BLUE", "RED", "YELLOW", "ORANGE", "CYAN", "PINK"]
    unless valid_colors.includes?(color)
      raise ArgumentError.new("Invalid LED color: #{color}")
    end
    message = {"device" => {"led" => {"mic_mute" => {"color" => color}}}}
    send_command(message, name: "led_mic_mute_color")
  end

  def get_device_led_mic_mute_color
    message = {"device" => {"led" => {"mic_mute" => {"color" => nil}}}}
    send_command(message)
  end

  def set_device_led_mic_on_color(color : String)
    valid_colors = ["LIGHT_GREEN", "GREEN", "BLUE", "RED", "YELLOW", "ORANGE", "CYAN", "PINK"]
    unless valid_colors.includes?(color)
      raise ArgumentError.new("Invalid LED color: #{color}")
    end
    message = {"device" => {"led" => {"mic_on" => {"color" => color}}}}
    send_command(message, name: "led_mic_on_color")
  end

  def get_device_led_mic_on_color
    message = {"device" => {"led" => {"mic_on" => {"color" => nil}}}}
    send_command(message)
  end

  def set_device_led_show_farend_activity(enable : Bool)
    message = {"device" => {"led" => {"show_farend_activity" => enable}}}
    send_command(message, name: "led_farend_activity")
  end

  def get_device_led_show_farend_activity
    message = {"device" => {"led" => {"show_farend_activity" => nil}}}
    send_command(message)
  end

  # === Beam Orientation Methods ===

  def set_beam_orientation_offset(offset : Int32)
    # Valid options: 0, 90, 180, 270
    valid_offsets = [0, 90, 180, 270]
    unless valid_offsets.includes?(offset)
      raise ArgumentError.new("Invalid beam orientation offset: #{offset}")
    end
    message = {"beam" => {"orientation" => {"offset" => offset}}}
    send_command(message, name: "beam_orientation")
  end

  def get_beam_orientation_offset
    message = {"beam" => {"orientation" => {"offset" => nil}}}
    send_command(message)
  end

  def set_beam_orientation_visual(enable : Bool)
    message = {"beam" => {"orientation" => {"visual" => enable}}}
    send_command(message, name: "beam_visual_orientation")
  end

  def get_beam_orientation_visual
    message = {"beam" => {"orientation" => {"visual" => nil}}}
    send_command(message)
  end

  # === Convenience Methods ===

  def mute
    set_mute(true)
  end

  def unmute
    set_mute(false)
  end

  def identify
    set_device_identification_visual(true)
  end

  def stop_identify
    set_device_identification_visual(false)
  end

  # === Status Query Methods ===

  def query_device_status
    get_audio_mute_status
    get_audio_room_in_use
    get_meter_beam_azimuth
    get_meter_beam_elevation
    get_meter_input_peak
  end

  def status
    {
      "protocol_version"  => self[:protocol_version]?,
      "muted"             => self[:muted]?,
      "room_in_use"       => self[:room_in_use]?,
      "beam_azimuth"      => self[:beam_azimuth]?,
      "beam_elevation"    => self[:beam_elevation]?,
      "input_peak_level"  => self[:input_peak_level]?,
      "ref1_rms_level"    => self[:ref1_rms_level]?,
      "device_name"       => self[:device_name]?,
      "device_location"   => self[:device_location]?,
      "device_position"   => self[:device_position]?,
      "firmware_version"  => self[:firmware_version]?,
      "serial_number"     => self[:serial_number]?,
      "led_brightness"    => self[:led_brightness]?,
      "installation_type" => self[:installation_type]?,
      "out1_attenuation"  => self[:out1_attenuation]?,
      "out2_gain"         => self[:out2_gain]?,
      "ref1_gain"         => self[:ref1_gain]?,
    }
  end

  # === Private Methods ===

  private def send_command(message : Hash, **options)
    json_data = message.to_json
    logger.debug { "Sending: #{json_data}" }
    send(json_data.to_slice, **options)
  end

  private def handle_response(message : JSON::Any, task : PlaceOS::Driver::Task)
    # Check for OSC error format
    if error_data = message["osc"]?.try(&.["error"]?)
      error_msg = error_data.to_s
      logger.warn { "Command failed: #{error_msg}" }
      task.abort(error_msg)
      return
    end

    # Process successful response - update state and notify task
    update_state_from_message(message)
    task.success(message)
  end

  private def handle_notification(message : JSON::Any)
    logger.debug { "Notification: #{message}" }
    update_state_from_message(message)
  end

  private def update_state_from_message(message : JSON::Any)
    # Handle OSC responses
    if osc = message["osc"]?
      if version = osc["version"]?
        self[:protocol_version] = version.as_s
      end
    end

    # Handle metering responses (m namespace)
    if m = message["m"]?
      if beam = m["beam"]?
        if azimuth = beam["azimuth"]?
          self[:beam_azimuth] = azimuth.as_i unless azimuth.raw.nil?
        end
        if elevation = beam["elevation"]?
          self[:beam_elevation] = elevation.as_i unless elevation.raw.nil?
        end
      end
      if in1 = m["in1"]?
        if peak = in1["peak"]?
          self[:input_peak_level] = peak.as_i unless peak.raw.nil?
        end
      end
      if ref1 = m["ref1"]?
        if rms = ref1["rms"]?
          self[:ref1_rms_level] = rms.as_i unless rms.raw.nil?
        end
      end
    end

    # Handle audio responses
    if audio = message["audio"]?
      if mute = audio["mute"]?
        self[:muted] = mute.as_bool unless mute.raw.nil?
      end
      if room_in_use = audio["room_in_use"]?
        self[:room_in_use] = room_in_use.as_bool unless room_in_use.raw.nil?
      end
      if installation_type = audio["installation_type"]?
        self[:installation_type] = installation_type.as_s unless installation_type.raw.nil?
      end

      # Audio output controls
      if out1 = audio["out1"]?
        if attenuation = out1["attenuation"]?
          self[:out1_attenuation] = attenuation.as_i unless attenuation.raw.nil?
        end
      end
      if out2 = audio["out2"]?
        if gain = out2["gain"]?
          self[:out2_gain] = gain.as_i unless gain.raw.nil?
        end
      end
      if ref1 = audio["ref1"]?
        if gain = ref1["gain"]?
          self[:ref1_gain] = gain.as_i unless gain.raw.nil?
        end
        if farend_auto = ref1["farend_auto_adjust_enable"]?
          self[:ref1_farend_auto_adjust] = farend_auto.as_bool unless farend_auto.raw.nil?
        end
      end
    end

    # Handle device responses
    if device = message["device"]?
      if identity = device["identity"]?
        if version = identity["version"]?
          self[:firmware_version] = version.as_s
        end
        if vendor = identity["vendor"]?
          self[:vendor] = vendor.as_s
        end
        if product = identity["product"]?
          self[:product] = product.as_s
        end
        if serial = identity["serial"]?
          self[:serial_number] = serial.as_s
        end
        if hw_revision = identity["hw_revision"]?
          self[:hw_revision] = hw_revision.as_s
        end
      end

      if identification = device["identification"]?
        if visual = identification["visual"]?
          self[:identification_visual] = visual.as_bool unless visual.raw.nil?
        end
      end

      if name = device["name"]?
        self[:device_name] = name.as_s unless name.raw.nil?
      end
      if location = device["location"]?
        self[:device_location] = location.as_s unless location.raw.nil?
      end
      if position = device["position"]?
        self[:device_position] = position.as_s unless position.raw.nil?
      end

      # LED responses
      if led = device["led"]?
        if brightness = led["brightness"]?
          self[:led_brightness] = brightness.as_i unless brightness.raw.nil?
        end
        if custom = led["custom"]?
          if color = custom["color"]?
            self[:led_custom_color] = color.as_s unless color.raw.nil?
          end
          if active = custom["active"]?
            self[:led_custom_active] = active.as_bool unless active.raw.nil?
          end
        end
        if mic_mute = led["mic_mute"]?
          if color = mic_mute["color"]?
            self[:led_mic_mute_color] = color.as_s unless color.raw.nil?
          end
        end
        if mic_on = led["mic_on"]?
          if color = mic_on["color"]?
            self[:led_mic_on_color] = color.as_s unless color.raw.nil?
          end
        end
        if farend_activity = led["show_farend_activity"]?
          self[:led_farend_activity] = farend_activity.as_bool unless farend_activity.raw.nil?
        end
      end
    end

    # Handle beam orientation responses
    if beam = message["beam"]?
      if orientation = beam["orientation"]?
        if offset = orientation["offset"]?
          self[:beam_orientation_offset] = offset.as_i unless offset.raw.nil?
        end
        if visual = orientation["visual"]?
          self[:beam_orientation_visual] = visual.as_bool unless visual.raw.nil?
        end
      end
    end
  end
end
