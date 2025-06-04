require "placeos-driver"
require "placeos-driver/interface/muteable"
require "./models"

class Sennheiser::TeamConnectCM < PlaceOS::Driver
  include Interface::AudioMuteable
  include Sennheiser::Models
  descriptive_name "TeamConnect Ceiling Medium"
  generic_name :TCCM

  uri_base "https://device_ip"

  default_settings({
    username:      "api",
    password:      "",
    device_ip:     "192.168.0.1",
    debug_payload: false,
  })

  @debug_payload : Bool = false
  @username : String = ""
  @password : String = ""

  def on_update
    @username = setting?(String, :username) || "api"
    @password = setting(String, :password)
    device_ip = setting(String, :device_ip)
    @debug_payload = setting?(Bool, :debug_payload) || false

    @uri_base = "https://#{device_ip}"
  end

  # ====================
  # Audio Mute Interface
  # ====================

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    set_mute_status(state)
  end

  # Device
  def_get :device_identity, "/api/device/identity"

  def_get :device_identification, "/api/device/identification"
  def_put :set_device_dentification, "/api/device/identification", visual: Bool

  def_get :device_site, "/api/device/site"
  def_get :device_state, "/api/device/state"

  def_get :device_led_ring, "/api/device/leds/ring"
  def_put :set_device_led_ring, "/api/device/leds/ring", brightness: 0..5, show_farend_activity: Bool, mic_on: MicTuple, mic_mute: MicTuple, mic_custom: MicCustomTuple

  # Audio
  def_get :mute_status, "/api/audio/outputs/global/mute"
  def_put :set_mute_status, "/api/audio/outputs/global/mute", enabled: Bool

  def_get :beam_settings, "/api/audio/inputs/microphone/beam"
  def_put :set_beam_settings, "/api/audio/inputs/microphone/beam", installation_type: InstallationType, source_detection_threshold: DetectionThreshold, offset: 0..330

  def_get :beam_direction, "/api/audio/inputs/microphone/beam/direction"
  def_get :microphone_input_level, "/api/audio/inputs/microphone/level"
  def_get :digital_reference_input_level, "/api/audio/inputs/reference/level"
  def_get :room_in_use, "/api/audio/roomInUse"
  def_get :room_in_use_activity_level, "/api/audio/roomInUse/activityLevel"
  def_get :room_in_use_config, "/api/audio/roomInUse/config"

  def_get :analog_output_settings, "/api/audio/outputs/analog"
  def_put :set_analog_output_settings, "/api/audio/outputs/analog", gain: -18..0, switch: SwitchOutput

  def api_get(resource : String, query : String? = nil)
    headers = get_headers
    logger.debug { {msg: "GET #{resource}:", headers: headers.to_json, query: query.to_s} } if @debug_payload
    uri = query.presence ? resource + "?#{query}" : resource
    response = get(uri, headers: headers)
    raise "failed to get #{resource}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def api_put(uri : String, payload : String)
    headers = get_headers
    logger.debug { {msg: "PUT HTTP Data:", headers: headers.to_json, payload: payload} } if @debug_payload
    response = put(uri, headers: headers, body: payload)
    raise "failed to invoke put command, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  private def get_headers
    HTTP::Headers{
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
      "Authorization" => "Basic #{Base64.strict_encode("#{@username}:#{@password}")}",
    }
  end
end
