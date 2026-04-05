require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "http-client-digest_auth"
require "./ppnd_models"

# Documentation: PPND WEB API
# Base URL: https://{ip-address}/api/v1/
# Protocol: HTTP/HTTPS with JSON responses
# Authentication: Digest
# Change from version 2.99 => 3.00

class Panasonic::Projector::PPND < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    COMPUTER
    HDMI
    HDMI1
    HDMI2
    MemoryViewer
    Network
    DigitalLink
  end

  include Interface::InputSelection(Input)

  # Discovery Information
  generic_name :Display
  descriptive_name "Panasonic Projector PPND API"
  uri_base "https://projector"

  default_settings({
    digest_auth: {
      username: "admin",
      password: "panasonic",
    },
    api_version:   "v1",
    poll_interval: 30,
    enable_https:  true,
  })

  @digest_auth : HTTP::Client::DigestAuth = HTTP::Client::DigestAuth.new
  @auth_challenge = ""
  @auth_uri : URI = URI.parse("http://localhost")
  @api_version : String = "v1"
  @poll_interval : Int32 = 30

  @power_target : Bool? = nil
  @input_target : Input? = nil

  def on_load
    # Initialize digest auth
    @digest_auth = HTTP::Client::DigestAuth.new
    @auth_challenge = ""
    @auth_uri = URI.parse(config.uri.not_nil!)

    on_update
  end

  def on_update
    @power_target = nil
    @input_target = nil

    # Update digest auth credentials
    if auth_info = setting?(Hash(String, String), :digest_auth)
      @auth_uri.user = auth_info["username"]?
      @auth_uri.password = auth_info["password"]?
    end

    @api_version = setting?(String, :api_version) || "v1"
    @poll_interval = setting?(Int32, :poll_interval) || 30

    # Schedule periodic status polling
    schedule.clear

    query_device_info

    schedule.every(@poll_interval.seconds) do
      query_power_status
      query_input_status
      query_temperatures
      query_av_mute_status
      query_lights
      query_errors

      # freeze not supported
      # query_freeze_status
    end
  end

  # ====== Authentication helpers ======

  private def get_with_digest_auth(path : String, retry_count : Int32 = 0)
    if retry_count >= 2
      raise "Authentication failure"
    end

    # Full path includes version
    full_path = "/api/#{@api_version}#{path}"

    # Set up the URI for digest auth calculation
    @auth_uri.path = full_path
    @auth_uri.query = nil

    # Try request with auth if we have a challenge
    request_headers = HTTP::Headers.new
    if !@auth_challenge.empty?
      auth_header = @digest_auth.auth_header(@auth_uri, @auth_challenge, "GET")
      request_headers["Authorization"] = auth_header
    end

    response = get(full_path, headers: request_headers)

    case response.status_code
    when 401
      # Save challenge and retry
      if challenge = response.headers["WWW-Authenticate"]?
        @auth_challenge = challenge
        @digest_auth = HTTP::Client::DigestAuth.new
        get_with_digest_auth(path, retry_count: retry_count + 1)
      else
        raise "Authentication failure - no challenge provided"
      end
    when 503
      raise "Device unavailable (503)"
    else
      logger.debug { "response: #{response.body}" }
      response
    end
  end

  private def put_with_digest_auth(path : String, body : String, retry_count : Int32 = 0)
    if retry_count >= 2
      raise "Authentication failure"
    end

    # Full path includes version
    full_path = "/api/#{@api_version}#{path}"

    # Set up the URI for digest auth calculation
    @auth_uri.path = full_path
    @auth_uri.query = nil

    # Try request with auth if we have a challenge
    request_headers = HTTP::Headers.new
    request_headers["Content-Type"] = "application/json"
    if !@auth_challenge.empty?
      auth_header = @digest_auth.auth_header(@auth_uri, @auth_challenge, "PUT")
      request_headers["Authorization"] = auth_header
    end

    response = put(full_path, body: body, headers: request_headers)

    case response.status_code
    when 401
      # Save challenge and retry
      if challenge = response.headers["WWW-Authenticate"]?
        @auth_challenge = challenge
        @digest_auth = HTTP::Client::DigestAuth.new
        put_with_digest_auth(path, body, retry_count: retry_count + 1)
      else
        raise "Authentication failure - no challenge provided"
      end
    when 503
      raise "Device unavailable (503)"
    when 409
      raise "Conflict - device busy (409)"
    else
      logger.debug { "response: #{response.body}" }
      response
    end
  end

  # ====== Powerable Interface ======

  def power(state : Bool)
    @power_target = state

    body = {"power-state": state ? "on" : "standby"}.to_json
    response = put_with_digest_auth("/power", body)

    unless response.success?
      raise "Power command failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::PowerState.from_json(response.body)
    self[:power] = result.state == "on"

    result.state == "on"
  end

  def power?(**options)
    query_power_status
  end

  def query_power_status
    response = get_with_digest_auth("/power")

    unless response.success?
      raise "Power query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::PowerState.from_json(response.body)

    power_on = result.state == "on"
    self[:power] = power_on

    power_target = @power_target
    if !power_target.nil?
      if power_on == power_target
        @power_target = nil
      else
        power(power_target)
      end
    end

    power_on
  end

  # ====== Input Selection ======

  INPUT_MAPPING = {
    Input::COMPUTER     => "COMPUTER",
    # HDMI defaults to 1 as per input target below
    # Input::HDMI         => "HDMI1",
    Input::HDMI1        => "HDMI1",
    Input::HDMI2        => "HDMI2",
    Input::MemoryViewer => "MEMORY VIEWER",
    Input::Network      => "NETWORK",
    Input::DigitalLink  => "DIGITAL LINK",
  }

  INPUT_REVERSE_MAPPING = INPUT_MAPPING.invert

  def switch_to(input : Input)
    input = Input::HDMI1 if input.hdmi?
    @input_target = input

    unmute if self[:mute]?

    input_str = INPUT_MAPPING[input]
    body = {"input-state": input_str}.to_json

    response = put_with_digest_auth("/input", body)

    unless response.success?
      raise "Input switch failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::InputState.from_json(response.body)
    self[:input] = INPUT_REVERSE_MAPPING[result.state]?

    result.state
  end

  def query_input_status
    response = get_with_digest_auth("/input")

    unless response.success?
      raise "Input query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::InputState.from_json(response.body)
    current_input = INPUT_REVERSE_MAPPING[result.state]?
    self[:input] = current_input

    if input_target = @input_target
      if current_input == input_target
        @input_target = nil
      else
        switch_to(input_target)
      end
    end

    current_input
  end

  # ====== Shutter Control ======

  def mute(state : Bool = true,
           index : Int32 | String = 0,
           layer : MuteLayer = MuteLayer::AudioVideo,)
    body = {"av-mute-state": state ? "on" : "off"}.to_json

    response = put_with_digest_auth("/av-mute", body)

    unless response.success?
      raise "Shutter command failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::ShutterState.from_json(response.body)
    self[:av_mute] = result.state == "on"

    result.state
  end

  def query_av_mute_status
    response = get_with_digest_auth("/av-mute")

    unless response.success?
      raise "Shutter query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::ShutterState.from_json(response.body)
    self[:av_mute] = result.state == "on"

    result.state
  end

  # ====== Freeze Control ======

  # only accessible when the projector is on
  def freeze(state : Bool)
    body = {state: state ? "on" : "off"}.to_json

    response = put_with_digest_auth("/freeze", body)

    unless response.success?
      raise "Freeze command failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::FreezeState.from_json(response.body)
    self[:freeze] = result.state == "on"

    result.state == "on"
  end

  def query_freeze_status
    response = get_with_digest_auth("/freeze")

    unless response.success?
      raise "Freeze query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::FreezeState.from_json(response.body)
    self[:freeze] = result.state == "on"

    result.state == "on"
  end

  # ====== Status Queries ======

  def query_signal
    response = get_with_digest_auth("/signal")

    unless response.success?
      raise "Signal query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::SignalInformation.from_json(response.body)
    self[:signal_info] = result.information
    self[:no_signal] = result.information == "NO SIGNAL"

    result.information
  end

  def query_operating_mode
    response = get_with_digest_auth("/operating-mode")

    unless response.success?
      raise "Operating mode query failed: #{response.status_code}"
    end

    JSON.parse(response.body)
  end

  enum OpMode
    Normal
    Eco
    Quiet
    User1
    User2
    User3
  end

  def operating_mode(mode : OpMode)
    body = %({"operating-mode-state": "#{mode.to_s.downcase}"})
    response = put_with_digest_auth("/operating-mode", body)

    unless response.success?
      raise "Operating mode command failed: #{response.status_code} - #{response.body}"
    end

    JSON.parse(response.body)
  end

  def query_device_schedule
    response = get_with_digest_auth("/schedule")

    unless response.success?
      raise "Schedule query failed: #{response.status_code}"
    end

    JSON.parse(response.body)
  end

  def query_errors
    response = get_with_digest_auth("/error")

    unless response.success?
      raise "Error query failed: #{response.status_code}"
    end

    errors = Array(Panasonic::Projector::ErrorStatus).from_json(response.body, root: "error").reject do |error|
      error.error_kind == "no error"
    end
    self[:errors] = errors
    self[:error_count] = errors.size
    self[:has_errors] = !errors.empty?

    errors
  end

  def query_lights
    response = get_with_digest_auth("/lights")

    unless response.success?
      raise "Lights query failed: #{response.status_code}"
    end

    lights_response = LightsResponse.from_json(response.body)
    lights = lights_response.lights
    self[:lights] = lights

    lights
  end

  def query_device_info
    response = get_with_digest_auth("/device-information")

    unless response.success?
      raise "Device info query failed: #{response.status_code}"
    end

    info = Panasonic::Projector::DeviceInformation.from_json(response.body)
    self[:model] = info.model_name
    self[:serial_number] = info.serial_no
    self[:projector_name] = info.projector_name
    self[:mac_address] = info.macaddress

    info
  end

  def query_firmware_version
    response = get_with_digest_auth("/version")

    unless response.success?
      raise "Firmware query failed: #{response.status_code}"
    end

    version = Panasonic::Projector::FirmwareVersion.from_json(response.body)
    self[:firmware_version] = version.main_version

    version.main_version
  end

  def query_temperatures
    response = get_with_digest_auth("/temperatures")

    unless response.success?
      raise "Temperature query failed: #{response.status_code}"
    end

    temps_response = TemperaturesResponse.from_json(response.body)
    temps = temps_response.temperatures
    self[:temperatures] = temps

    temps
  end

  # ====== Settings ======

  def configure_ntp(sync : Bool, server : String)
    body = {"ntp-sync": sync ? "on" : "off", "ntp-server": server}.to_json

    response = put_with_digest_auth("/ntp", body)

    unless response.success?
      raise "NTP configuration failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::NTPSettings.from_json(response.body)
    self[:ntp_sync] = result.ntp_sync == "on"
    self[:ntp_server] = result.ntp_server

    result
  end

  def query_ntp_settings
    response = get_with_digest_auth("/ntp")

    unless response.success?
      raise "NTP query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::NTPSettings.from_json(response.body)
    self[:ntp_sync] = result.ntp_sync == "on"
    self[:ntp_server] = result.ntp_server

    result
  end

  def configure_https(enabled : Bool)
    body = {state: enabled ? "on" : "off"}.to_json

    response = put_with_digest_auth("/https", body)

    unless response.success?
      raise "HTTPS configuration failed: #{response.status_code} - #{response.body}"
    end

    result = Panasonic::Projector::HTTPSConfig.from_json(response.body)
    self[:https_enabled] = result.state == "on"

    result.state == "on"
  end

  def query_https_config
    response = get_with_digest_auth("/https")

    unless response.success?
      raise "HTTPS query failed: #{response.status_code}"
    end

    result = Panasonic::Projector::HTTPSConfig.from_json(response.body)
    self[:https_enabled] = result.state == "on"

    result.state == "on"
  end
end
