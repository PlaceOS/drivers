require "placeos-driver"
require "placeos-driver/interface/muteable"

class Sennheiser::TCC2SSCv1 < PlaceOS::Driver
  include Interface::AudioMuteable

  descriptive_name "Sennheiser TCC2 Microphone (SSCv1)"
  generic_name :TCC2
  description "Driver for Sennheiser TCC2 TeamConnect Ceiling Microphone using Sound Control Protocol v1. Uses UDP port 45 with OSC-like JSON messages."

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
    # Get initial device state
    get_device_info
    get_audio_status

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

  # === Core Control Methods ===

  def set_mute(muted : Bool)
    message = {
      "path"   => "/audio/mute",
      "method" => "set",
      "args"   => {
        "enabled" => muted,
      },
    }
    send_command(message, name: "mute")
  end

  def get_mute_status
    message = {
      "path"   => "/audio/mute",
      "method" => "get",
    }
    send_command(message)
  end

  def set_gain(level : Int32)
    # Clamp gain to typical range
    clamped_level = level.clamp(-60, 12)
    message = {
      "path"   => "/audio/gain",
      "method" => "set",
      "args"   => {
        "level" => clamped_level,
      },
    }
    send_command(message, name: "gain")
  end

  def get_gain
    message = {
      "path"   => "/audio/gain",
      "method" => "get",
    }
    send_command(message)
  end

  def set_beam_direction(azimuth : Int32, elevation : Int32 = 0)
    # Clamp values to valid ranges
    azimuth_clamped = azimuth.clamp(0, 359)
    elevation_clamped = elevation.clamp(-30, 30)

    message = {
      "path"   => "/beam/direction",
      "method" => "set",
      "args"   => {
        "azimuth"   => azimuth_clamped,
        "elevation" => elevation_clamped,
      },
    }
    send_command(message, name: "beam_direction")
  end

  def get_beam_direction
    message = {
      "path"   => "/beam/direction",
      "method" => "get",
    }
    send_command(message)
  end

  def get_device_info
    message = {
      "path"   => "/device/info",
      "method" => "get",
    }
    send_command(message)
  end

  def get_audio_levels
    message = {
      "path"   => "/audio/levels",
      "method" => "get",
    }
    send_command(message)
  end

  def get_audio_status
    message = {
      "path"   => "/audio/status",
      "method" => "get",
    }
    send_command(message)
  end

  def identify_device(enable : Bool = true)
    message = {
      "path"   => "/device/identify",
      "method" => "set",
      "args"   => {
        "enabled" => enable,
      },
    }
    send_command(message)
  end

  def set_led_brightness(level : Int32)
    # Clamp brightness to valid range (0-100)
    clamped_level = level.clamp(0, 100)
    message = {
      "path"   => "/device/leds/brightness",
      "method" => "set",
      "args"   => {
        "level" => clamped_level,
      },
    }
    send_command(message, name: "led_brightness")
  end

  def set_led_color(red : Int32, green : Int32, blue : Int32)
    # Clamp RGB values to 0-255
    r = red.clamp(0, 255)
    g = green.clamp(0, 255)
    b = blue.clamp(0, 255)

    message = {
      "path"   => "/device/leds/color",
      "method" => "set",
      "args"   => {
        "red"   => r,
        "green" => g,
        "blue"  => b,
      },
    }
    send_command(message, name: "led_color")
  end

  # === Convenience Methods ===

  def mute
    set_mute(true)
  end

  def unmute
    set_mute(false)
  end

  def identify
    identify_device(true)
  end

  def stop_identify
    identify_device(false)
  end

  # === Status Query Methods ===

  def query_device_status
    get_mute_status
    get_gain
    get_beam_direction
    get_audio_levels
  end

  def status
    {
      "muted"          => self[:muted]?,
      "gain"           => self[:gain_level]?,
      "beam_azimuth"   => self[:beam_azimuth]?,
      "beam_elevation" => self[:beam_elevation]?,
      "audio_level"    => self[:audio_level]?,
      "device_info"    => self[:device_info]?,
    }
  end

  # === Private Methods ===

  private def send_command(message : Hash, **options)
    json_data = message.to_json
    logger.debug { "Sending: #{json_data}" }
    send(json_data.to_slice, **options)
  end

  private def handle_response(message : JSON::Any, task : PlaceOS::Driver::Task)
    path = message["path"]?.try(&.as_s) || ""
    method = message["method"]?.try(&.as_s) || ""
    status_code = message["status"]?.try(&.as_i) || 200

    if status_code >= 400
      error_msg = message["error"]?.try(&.as_s) || "Request failed"
      logger.warn { "Command failed: #{error_msg}" }
      task.abort(error_msg)
      return
    end

    data = message["data"]?
    update_state(path, data) if data
    task.success(data)
  end

  private def handle_notification(message : JSON::Any)
    path = message["path"]?.try(&.as_s) || ""
    data = message["data"]?

    logger.debug { "Notification from #{path}: #{data}" }
    update_state(path, data) if data
  end

  private def update_state(path : String, data : JSON::Any)
    case path
    when "/audio/mute"
      if enabled = data.dig?("enabled")
        self[:muted] = enabled.as_bool
      end
    when "/audio/gain"
      if level = data.dig?("level")
        self[:gain_level] = level.as_i
      end
    when "/beam/direction"
      if azimuth = data.dig?("azimuth")
        self[:beam_azimuth] = azimuth.as_i
      end
      if elevation = data.dig?("elevation")
        self[:beam_elevation] = elevation.as_i
      end
    when "/audio/levels"
      if level = data.dig?("input_level")
        self[:audio_level] = level.as_i
      end
    when "/audio/status"
      # Update multiple audio-related states
      if mute_data = data.dig?("mute")
        self[:muted] = mute_data.as_bool
      end
      if gain_data = data.dig?("gain")
        self[:gain_level] = gain_data.as_i
      end
    when "/device/info"
      self[:device_info] = data.as_h
      if name = data.dig?("name")
        self[:device_name] = name.as_s
      end
      if version = data.dig?("firmware_version")
        self[:firmware_version] = version.as_s
      end
    when "/device/leds/brightness"
      if level = data.dig?("level")
        self[:led_brightness] = level.as_i
      end
    when "/device/leds/color"
      if color_data = data.as_h?
        self[:led_color] = color_data
      end
    else
      # Store unknown paths as generic data
      sanitized_path = path.gsub("/", "_").gsub(/^_/, "")
      self[sanitized_path] = data.as_h
    end
  end
end
