require "placeos-driver"
require "placeos-driver/interface/muteable"
require "./sscv2_models"

# https://docs.cloud.sennheiser.com/en-us/api-docs/api-docs/open-api-tc-ceiling-medium.html#/FastResource/get_api_audio_roomInUse_activityLevel

class Sennheiser::SSCv2Driver < PlaceOS::Driver
  include Interface::AudioMuteable
  
  descriptive_name "Sennheiser Sound Control Protocol v2"
  generic_name :AudioDevice
  description "Driver for Sennheiser TeamConnect Ceiling Microphone (TCCM) using SSCv2 protocol. Requires third-party access to be enabled in Sennheiser Control Cockpit with configured password. Automatically subscribes to real-time device state, beam direction, audio levels, and room occupancy when running_specs is false or nil."

  uri_base "https://device_ip"

  default_settings({
    basic_auth: {
      username: "api",
      password: "configured_password",
    },
    running_specs:          true,
    subscription_resources: [
      "/api/device/site",
    ] of String,
    # Note: /api/device/status and /api/device/info are automatically
    # subscribed when running_specs is false or nil
  })

  @username : String = "api"
  @password : String = ""
  @subscription_resources : Array(String) = [] of String
  @running_specs : Bool = true
  @subscription_processor : Sennheiser::SSCv2::SubscriptionProcessor?

  def on_load
    on_update
  end

  def on_update
    # Extract basic auth credentials
    if basic_auth = setting?(Hash(String, String), :basic_auth)
      @username = basic_auth["username"]? || "api"
      @password = basic_auth["password"]? || ""
    else
      @username = "api"
      @password = ""
    end

    @subscription_resources = setting?(Array(String), :subscription_resources) || [] of String
    running_specs_setting = setting?(Bool, :running_specs)
    @running_specs = running_specs_setting.nil? ? false : running_specs_setting

    # Stop existing subscription processor
    @subscription_processor.try(&.stop)
    @subscription_processor = nil

    # Don't start SSE subscriptions during specs
    return if @running_specs

    # Add default subscriptions
    default_resources = [
      "/api/device/state",
      "/api/device/identity",
      "/api/audio/inputs/microphone/beam/direction",
      "/api/audio/inputs/microphone/level",
      "/api/audio/roomInUse",
      "/api/audio/roomInUse/activityLevel",
    ]
    default_resources.each do |resource|
      @subscription_resources << resource unless @subscription_resources.includes?(resource)
    end

    # Initialize subscription processor
    base_url = config.uri.not_nil!.to_s.rchop("/")
    processor = Sennheiser::SSCv2::SubscriptionProcessor.new(base_url, @username, @password)

    # Set up callbacks
    processor.on_data do |resource_path, data|
      handle_subscription_data(resource_path, data)
    end

    processor.on_error do |error|
      logger.warn { "SSE subscription error: #{error}" }
    end

    @subscription_processor = processor
  end

  def connected
    return if @running_specs

    # Start SSE subscription
    spawn { start_subscription }
  end

  def disconnected
    @subscription_processor.try(&.stop)
  end

  # === API Methods ===

  # SSC and Device Info
  def ssc_version
    get("/api/ssc/version")
  end

  def ssc_schema
    get("/api/ssc/schema")
  end

  def device_identity
    get("/api/device/identity")
  end

  def device_identification
    get("/api/device/identification")
  end

  def set_device_identification(visual : Bool)
    put("/api/device/identification", body: {visual: visual}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def device_site
    get("/api/device/site")
  end

  def device_state
    get("/api/device/state")
  end

  def firmware_update_state
    get("/api/firmware/update/state")
  end

  def set_device_name(deviceName : String)
    put("/api/device/site", body: {deviceName: deviceName}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def set_device_location(location : String)
    put("/api/device/site", body: {location: location}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def set_device_position(position : String)
    put("/api/device/site", body: {position: position}.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Audio Control
  def audio_global_mute
    get("/api/audio/outputs/global/mute")
  end

  def set_audio_global_mute(enabled : Bool)
    put("/api/audio/outputs/global/mute", body: {enabled: enabled}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def microphone_beam
    get("/api/audio/inputs/microphone/beam")
  end

  def set_microphone_beam(installationType : String? = nil, sourceDetectionThreshold : String? = nil, offset : Int32? = nil)
    body = {} of String => JSON::Any::Type
    body["installationType"] = installationType if installationType
    body["sourceDetectionThreshold"] = sourceDetectionThreshold if sourceDetectionThreshold
    body["offset"] = offset.to_i64 if offset
    put("/api/audio/inputs/microphone/beam", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def beam_direction
    get("/api/audio/inputs/microphone/beam/direction")
  end

  def microphone_level
    get("/api/audio/inputs/microphone/level")
  end

  def reference_level
    get("/api/audio/inputs/reference/level")
  end

  def room_in_use
    get("/api/audio/roomInUse")
  end

  def room_in_use_activity_level
    get("/api/audio/roomInUse/activityLevel")
  end

  def room_in_use_config
    get("/api/audio/roomInUse/config")
  end

  # Audio Outputs
  def analog_output
    get("/api/audio/outputs/analog")
  end

  def set_analog_output(gain : Int32? = nil, switch : String? = nil)
    body = {} of String => JSON::Any::Type
    body["gain"] = gain.to_i64 if gain
    body["switch"] = switch if switch
    put("/api/audio/outputs/analog", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def dante_farend_output
    get("/api/audio/outputs/dante/farEnd")
  end

  def set_dante_farend_output(gain : Int32? = nil, noiseGateEnabled : Bool? = nil, equalizerEnabled : Bool? = nil, delay : Int32? = nil)
    body = {} of String => JSON::Any::Type
    body["gain"] = gain.to_i64 if gain
    body["noiseGateEnabled"] = noiseGateEnabled unless noiseGateEnabled.nil?
    body["equalizerEnabled"] = equalizerEnabled unless equalizerEnabled.nil?
    body["delay"] = delay.to_i64 if delay
    put("/api/audio/outputs/dante/farEnd", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def dante_local_output
    get("/api/audio/outputs/dante/local")
  end

  def set_dante_local_output(gain : Int32? = nil, noiseGateEnabled : Bool? = nil, equalizerEnabled : Bool? = nil, voiceLiftEnabled : Bool? = nil, delay : Int32? = nil)
    body = {} of String => JSON::Any::Type
    body["gain"] = gain.to_i64 if gain
    body["noiseGateEnabled"] = noiseGateEnabled unless noiseGateEnabled.nil?
    body["equalizerEnabled"] = equalizerEnabled unless equalizerEnabled.nil?
    body["voiceLiftEnabled"] = voiceLiftEnabled unless voiceLiftEnabled.nil?
    body["delay"] = delay.to_i64 if delay
    put("/api/audio/outputs/dante/local", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Audio Inputs
  def reference_input
    get("/api/audio/inputs/dante/reference")
  end

  def set_reference_input(gain : Int32? = nil, farEndAutoAdjustEnabled : Bool? = nil)
    body = {} of String => JSON::Any::Type
    body["gain"] = gain.to_i64 if gain
    body["farEndAutoAdjustEnabled"] = farEndAutoAdjustEnabled unless farEndAutoAdjustEnabled.nil?
    put("/api/audio/inputs/dante/reference", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Audio Processing
  def voice_lift
    get("/api/audio/voiceLift")
  end

  def set_voice_lift(emergencyMuteThreshold : Int32? = nil, emergencyMuteTime : Int32? = nil)
    body = {} of String => JSON::Any::Type
    body["emergencyMuteThreshold"] = emergencyMuteThreshold.to_i64 if emergencyMuteThreshold
    body["emergencyMuteTime"] = emergencyMuteTime.to_i64 if emergencyMuteTime
    put("/api/audio/voiceLift", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def equalizer
    get("/api/audio/equalizer")
  end

  def set_equalizer(gains : Array(Int32))
    put("/api/audio/equalizer", body: {gains: gains}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def noise_gate
    get("/api/audio/noiseGate")
  end

  def set_noise_gate(threshold : Int32? = nil, holdTime : Int32? = nil)
    body = {} of String => JSON::Any::Type
    body["threshold"] = threshold.to_i64 if threshold
    body["holdTime"] = holdTime.to_i64 if holdTime
    put("/api/audio/noiseGate", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def denoiser
    get("/api/audio/inputs/microphone/denoiser")
  end

  def set_denoiser(setting : String)
    put("/api/audio/inputs/microphone/denoiser", body: {setting: setting}.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Zones
  def exclusion_zones
    get("/api/audio/inputs/microphone/exclusionZones")
  end

  def exclusion_zone(id : Int32)
    get("/api/audio/inputs/microphone/exclusionZones/#{id}")
  end

  def set_exclusion_zone(id : Int32, enabled : Bool? = nil, elevation_min : Int32? = nil, elevation_max : Int32? = nil, azimuth_min : Int32? = nil, azimuth_max : Int32? = nil)
    body = {} of String => (String | Int64 | Bool | Hash(String, Int64))
    body["enabled"] = enabled unless enabled.nil?

    if elevation_min || elevation_max
      elevation = {} of String => Int64
      elevation["min"] = elevation_min.to_i64 if elevation_min
      elevation["max"] = elevation_max.to_i64 if elevation_max
      body["elevation"] = elevation
    end

    if azimuth_min || azimuth_max
      azimuth = {} of String => Int64
      azimuth["min"] = azimuth_min.to_i64 if azimuth_min
      azimuth["max"] = azimuth_max.to_i64 if azimuth_max
      body["azimuth"] = azimuth
    end

    put("/api/audio/inputs/microphone/exclusionZones/#{id}", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def priority_zones
    get("/api/audio/inputs/microphone/priorityZones")
  end

  def priority_zone(id : Int32)
    get("/api/audio/inputs/microphone/priorityZones/#{id}")
  end

  def set_priority_zone(id : Int32, enabled : Bool? = nil, weight : Float32? = nil, elevation_min : Int32? = nil, elevation_max : Int32? = nil, azimuth_min : Int32? = nil, azimuth_max : Int32? = nil)
    body = {} of String => (String | Int64 | Bool | Float64 | Hash(String, Int64))
    body["enabled"] = enabled unless enabled.nil?
    body["weight"] = weight.to_f64 if weight

    if elevation_min || elevation_max
      elevation = {} of String => Int64
      elevation["min"] = elevation_min.to_i64 if elevation_min
      elevation["max"] = elevation_max.to_i64 if elevation_max
      body["elevation"] = elevation
    end

    if azimuth_min || azimuth_max
      azimuth = {} of String => Int64
      azimuth["min"] = azimuth_min.to_i64 if azimuth_min
      azimuth["max"] = azimuth_max.to_i64 if azimuth_max
      body["azimuth"] = azimuth
    end

    put("/api/audio/inputs/microphone/priorityZones/#{id}", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Device LEDs
  def led_ring
    get("/api/device/leds/ring")
  end

  def set_led_ring(brightness : Int32? = nil, showFarendActivity : Bool? = nil, micOn_color : String? = nil, micMute_color : String? = nil, micCustom_enabled : Bool? = nil, micCustom_color : String? = nil)
    body = {} of String => (String | Int64 | Bool | Hash(String, String) | Hash(String, String | Bool))
    body["brightness"] = brightness.to_i64 if brightness
    body["showFarendActivity"] = showFarendActivity unless showFarendActivity.nil?

    if micOn_color
      body["micOn"] = {"color" => micOn_color}
    end

    if micMute_color
      body["micMute"] = {"color" => micMute_color}
    end

    if micCustom_enabled || micCustom_color
      micCustom = {} of String => (String | Bool)
      micCustom["enabled"] = micCustom_enabled unless micCustom_enabled.nil?
      micCustom["color"] = micCustom_color if micCustom_color
      body["micCustom"] = micCustom
    end

    put("/api/device/leds/ring", body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  # Device Power
  def poe_daisychain
    get("/api/device/power/poe/daisychain")
  end

  # License Agreements
  def license_agreements_hash
    get("/api/device/licenseAgreements/hash")
  end

  def license_agreements_licenses
    get("/api/device/licenseAgreements/licenses")
  end

  # === Interface::AudioMuteable Implementation ===
  
  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    set_audio_global_mute(state)
  end

  # === Convenience Methods ===

  # Mute/unmute microphone
  def mute(state : Bool = true)
    set_audio_global_mute(state)
  end

  def unmute
    mute(false)
  end

  # Device identification (visual LED flash)
  def identify(enable : Bool = true)
    set_device_identification(enable)
  end

  # Quick beam configuration
  def configure_beam(installation_type : String, detection_threshold : String = "NormalRoom", offset : Int32 = 0)
    set_microphone_beam(installation_type, detection_threshold, offset)
  end

  # LED ring brightness control
  def set_brightness(level : Int32)
    set_led_ring(brightness: level)
  end

  # Set LED colors for different states
  def set_led_colors(mic_on : String? = nil, mic_mute : String? = nil)
    set_led_ring(micOn_color: mic_on, micMute_color: mic_mute)
  end

  # Quick equalizer presets
  def equalizer_flat
    set_equalizer([0, 0, 0, 0, 0, 0, 0])
  end

  def equalizer_voice_boost
    # Boost 1-4kHz range for voice clarity
    set_equalizer([0, 0, 2, 3, 3, 1, 0])
  end

  # Room sensing configuration
  def configure_room_sensing(trigger_time : Int32 = 15, release_time : Int32 = 300, threshold : Int32 = 10)
    # Note: This would require a PUT endpoint for room config which isn't in the current API
    # For now, users would need to use the web interface to configure this
    logger.info { "Room sensing config - use web interface: trigger=#{trigger_time}s, release=#{release_time}s, threshold=#{threshold}dB" }
  end

  # Get current audio status summary
  def audio_status
    {
      "muted"            => self[:global_mute]?.try(&.as_h).try(&.["enabled"]?),
      "beam_direction"   => self[:beam_direction]?,
      "microphone_level" => self[:microphone_level]?,
      "room_in_use"      => self[:room_in_use]?.try(&.as_h).try(&.["active"]?),
      "room_activity"    => self[:room_activity_level]?.try(&.as_h).try(&.["peak"]?),
    }
  end

  # Get device information summary
  def device_info
    {
      "identity" => self[:device_identity]?,
      "site"     => {
        "name"     => self[:device_name]?,
        "location" => self[:device_location]?,
        "position" => self[:device_position]?,
      },
      "state" => self[:device_state]?,
    }
  end

  # === Subscription Management ===

  def subscribe_to_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.subscribe_to_resources(resources))
  end

  def add_subscription_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.add_resources(resources))
  end

  def remove_subscription_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.remove_resources(resources))
  end

  def get_subscription_status
    processor = @subscription_processor

    if processor
      {
        "session_uuid"         => processor.session_uuid || "",
        "subscribed_resources" => processor.subscribed_resources,
        "running"              => processor.running,
      }
    else
      {
        "session_uuid"         => "",
        "subscribed_resources" => [] of String,
        "running"              => false,
      }
    end
  end

  # === Private Methods ===

  private def start_subscription
    processor = @subscription_processor
    return unless processor

    processor.start

    # Wait a moment for connection to establish, then subscribe to default resources
    sleep 2.seconds
    if !@subscription_resources.empty?
      processor.subscribe_to_resources(@subscription_resources)
    end
  end

  private def handle_subscription_data(resource_path : String, data : JSON::Any)
    logger.debug { "Received SSE data for #{resource_path}: #{data}" }

    # Update driver state based on resource path
    case resource_path
    when "/api/device/site"
      begin
        site_data = Sennheiser::SSCv2::DeviceSite.from_json(data.to_json)
        self[:device_name] = site_data.deviceName
        self[:device_location] = site_data.location
        self[:device_position] = site_data.position
      rescue JSON::ParseException
        logger.warn { "Failed to parse device site data: #{data}" }
      end
    when "/api/device/identity"
      self[:device_identity] = data.as_h
    when "/api/device/identification"
      self[:device_identification] = data.as_h
    when "/api/device/state"
      self[:device_state] = data.as_h
    when "/api/audio/outputs/global/mute"
      self[:global_mute] = data.as_h
    when "/api/audio/inputs/microphone/beam"
      self[:microphone_beam] = data.as_h
    when "/api/audio/inputs/microphone/beam/direction"
      self[:beam_direction] = data.as_h
    when "/api/audio/inputs/microphone/level"
      self[:microphone_level] = data.as_h
    when "/api/audio/inputs/reference/level"
      self[:reference_level] = data.as_h
    when "/api/audio/roomInUse"
      self[:room_in_use] = data.as_h
    when "/api/audio/roomInUse/activityLevel"
      self[:room_activity_level] = data.as_h
    when "/api/audio/outputs/analog"
      self[:analog_output] = data.as_h
    when "/api/audio/outputs/dante/farEnd"
      self[:dante_farend_output] = data.as_h
    when "/api/audio/outputs/dante/local"
      self[:dante_local_output] = data.as_h
    when "/api/audio/inputs/dante/reference"
      self[:reference_input] = data.as_h
    when "/api/audio/voiceLift"
      self[:voice_lift] = data.as_h
    when "/api/audio/equalizer"
      self[:equalizer] = data.as_h
    when "/api/audio/noiseGate"
      self[:noise_gate] = data.as_h
    when "/api/device/leds/ring"
      self[:led_ring] = data.as_h
    when "/api/device/power/poe/daisychain"
      self[:poe_daisychain] = data.as_h
    when "/api/audio/inputs/microphone/denoiser"
      self[:denoiser] = data.as_h
    when .starts_with?("/api/audio/inputs/microphone/exclusionZones/")
      zone_id = resource_path.split("/").last
      self["exclusion_zone_#{zone_id}"] = data.as_h
    when .starts_with?("/api/audio/inputs/microphone/priorityZones/")
      zone_id = resource_path.split("/").last
      self["priority_zone_#{zone_id}"] = data.as_h
    else
      # Store generic resource data
      resource_key = resource_path.gsub("/", "_").gsub(/^_/, "")
      self[resource_key] = data.as_h
    end
  end
end
