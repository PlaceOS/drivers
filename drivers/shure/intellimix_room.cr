require "placeos-driver"
require "placeos-driver/interface/muteable"

# Documentation: https://www.shure.com/en-US/docs/commandstrings/IntelliMixRoom
# TCP Port: 2244

class Shure::IntellimixRoom < PlaceOS::Driver
  include Interface::AudioMuteable

  tcp_port 2244
  descriptive_name "Shure IntelliMix Room Audio Processor"
  generic_name :AudioMixer
  description "Software-based digital signal processing for Shure networked microphones"

  default_settings({
    poll_channels: true,
    channel_count: 8,
  })

  def connected
    # Shure uses space + > as the response terminator
    transport.tokenizer = Tokenizer.new(" >")

    schedule.every(30.seconds) do
      logger.debug { "-- Polling device status" }
      do_poll
    end

    query_device_info
    query_input_count if setting?(Bool, :poll_channels)
  end

  def disconnected
    schedule.clear
  end

  # Device Information
  def query_device_info
    do_send "GET DEVICE_ID", name: :device_info
    do_send "GET MODEL", name: :device_model
    do_send "GET FW_VER", name: :firmware_version
  end

  def query_input_count
    do_send "GET INPUT_COUNT", name: :input_count
  end

  # Audio Input Controls
  def query_input_gain(channel : Int32)
    validate_channel(channel)
    do_send "GET #{channel} INPUT_GAIN", name: :input_gain
  end

  def set_input_gain(channel : Int32, gain : Float64)
    validate_channel(channel)
    raise "Gain must be between -100.0 and 20.0 dB, was #{gain}" unless gain.in?(-100.0..20.0)
    do_send "SET #{channel} INPUT_GAIN #{gain}", name: :input_gain
  end

  def query_input_mute(channel : Int32)
    validate_channel(channel)
    do_send "GET #{channel} INPUT_MUTE", name: :input_mute
  end

  def set_input_mute(channel : Int32, state : Bool)
    validate_channel(channel)
    val = state ? "ON" : "OFF"
    do_send "SET #{channel} INPUT_MUTE #{val}", name: :input_mute
  end

  # Audio Output Controls
  def query_output_gain(channel : Int32 = 1)
    validate_channel(channel)
    do_send "GET #{channel} OUTPUT_GAIN", name: :output_gain
  end

  def set_output_gain(channel : Int32, gain : Float64)
    validate_channel(channel)
    raise "Gain must be between -100.0 and 20.0 dB, was #{gain}" unless gain.in?(-100.0..20.0)
    do_send "SET #{channel} OUTPUT_GAIN #{gain}", name: :output_gain
  end

  def query_output_mute(channel : Int32 = 1)
    validate_channel(channel)
    do_send "GET #{channel} OUTPUT_MUTE", name: :output_mute
  end

  def set_output_mute(channel : Int32, state : Bool)
    validate_channel(channel)
    val = state ? "ON" : "OFF"
    do_send "SET #{channel} OUTPUT_MUTE #{val}", name: :output_mute
  end

  # Interface::AudioMuteable implementation
  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    channel = index.is_a?(String) ? index.to_i : index
    channel = 1 if channel == 0 # Default to channel 1 if 0 is specified
    set_output_mute(channel, state)
  end

  # Global Controls
  def query_master_gain
    do_send "GET MASTER_GAIN", name: :master_gain
  end

  def set_master_gain(gain : Float64)
    raise "Master gain must be between -100.0 and 20.0 dB, was #{gain}" unless gain.in?(-100.0..20.0)
    do_send "SET MASTER_GAIN #{gain}", name: :master_gain
  end

  def query_master_mute
    do_send "GET MASTER_MUTE", name: :master_mute
  end

  def set_master_mute(state : Bool)
    val = state ? "ON" : "OFF"
    do_send "SET MASTER_MUTE #{val}", name: :master_mute
  end

  # Presets
  def query_preset
    do_send "GET PRESET", name: :preset
  end

  def load_preset(number : Int32)
    raise "Preset must be between 1 and 10, was #{number}" unless number.in?(1..10)
    do_send "SET PRESET #{number}", name: :preset
  end

  # Audio Processing
  def query_noise_reduction(channel : Int32)
    validate_channel(channel)
    do_send "GET #{channel} NOISE_REDUCTION", name: :noise_reduction
  end

  def set_noise_reduction(channel : Int32, state : Bool)
    validate_channel(channel)
    val = state ? "ON" : "OFF"
    do_send "SET #{channel} NOISE_REDUCTION #{val}", name: :noise_reduction
  end

  def query_automatic_gain_control(channel : Int32)
    validate_channel(channel)
    do_send "GET #{channel} AGC", name: :agc
  end

  def set_automatic_gain_control(channel : Int32, state : Bool)
    validate_channel(channel)
    val = state ? "ON" : "OFF"
    do_send "SET #{channel} AGC #{val}", name: :agc
  end

  # Audio Level Monitoring
  def query_input_level(channel : Int32)
    validate_channel(channel)
    do_send "GET #{channel} INPUT_LEVEL", name: :input_level
  end

  def query_output_level(channel : Int32 = 1)
    validate_channel(channel)
    do_send "GET #{channel} OUTPUT_LEVEL", name: :output_level
  end

  def received(bytes, task)
    data = String.new(bytes)
    logger.debug { "-- received: #{data}" }

    # Remove the response wrapper and convert to parts
    # Response format: < REP parameter value >
    if data.starts_with?("< REP ")
      response_data = data[6..-3] # Remove "< REP " and " >"
    else
      # Handle error responses or other formats
      response_data = data.strip.gsub(/[<>]/, "").strip
    end

    parts = response_data.split
    return task.try(&.abort("Empty response")) if parts.empty?

    # Handle error responses
    if parts.first == "ERR"
      error_msg = parts.size > 1 ? parts[1..-1].join(" ") : "Unknown error"
      logger.error { "Device error: #{error_msg}" }
      return task.try(&.abort(error_msg))
    end

    # Parse response based on parameter structure
    case parts.size
    when 1
      # Simple parameter like PRESET
      param = parts[0].downcase
      self[param] = true
    when 2
      # Parameter with value like MODEL VALUE or MASTER_MUTE ON
      param = parts[0].downcase
      case param
      when "master_mute"
        self[param] = parts[1] == "ON"
      when "master_gain"
        self[param] = parts[1].to_f
      else
        self[param] = parse_value(parts[1])
      end
    when 3
      # Channel-specific parameter like 1 INPUT_GAIN -10.0
      channel = parts[0]
      param = parts[1].downcase
      value = parse_value(parts[2])

      case param
      when "input_mute", "output_mute"
        self["#{param}_#{channel}"] = parts[2] == "ON"
      when "input_gain", "output_gain", "input_level", "output_level"
        self["#{param}_#{channel}"] = parts[2].to_f
      when "noise_reduction", "agc"
        self["#{param}_#{channel}"] = parts[2] == "ON"
      else
        self["#{param}_#{channel}"] = parse_value(parts[2])
      end
    else
      # Handle multi-part responses or unknown formats
      logger.warn { "Unknown response format: #{response_data}" }
    end

    task.try(&.success)
  end

  private def parse_value(value_str : String)
    case value_str.upcase
    when "ON"   then true
    when "OFF"  then false
    when .to_i? then value_str.to_i
    when .to_f? then value_str.to_f
    else             value_str
    end
  end

  private def validate_channel(channel : Int32)
    max_channels = setting?(Int32, :channel_count) || 8
    raise "Channel must be between 1 and #{max_channels}, was #{channel}" unless channel.in?(1..max_channels)
  end

  private def do_poll
    query_master_mute
    query_preset

    if setting?(Bool, :poll_channels)
      channel_count = setting?(Int32, :channel_count) || 8
      (1..channel_count).each do |channel|
        query_input_mute(channel)
      end
    end
  end

  protected def do_send(*command, **options)
    cmd = "< #{command.join(' ')} >"
    logger.debug { "-- sending: #{cmd}" }
    send(cmd, **options)
  end
end
