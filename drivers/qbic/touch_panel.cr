require "placeos-driver"
require "uri"

# docs:  https://drive.google.com/file/d/1ytAML83qloy9o0WN6C1GWjJ1P-Hcq-WY/view

class Qbic::TouchPanel < PlaceOS::Driver
  descriptive_name "Qbic Touch Panel"
  generic_name :Panel

  default_settings({
    password: "12345678",
  })

  uri_base "https://192.168.12.0"

  USERNAME = "admin"
  @password : String = ""
  @auth_token : String = ""
  @refresh_token : String? = nil
  @expired : Bool = true

  def on_update
    @password = URI.encode_www_form setting(String, :password)

    transport.before_request do |request|
      request.headers["Content-Type"] = "application/json"
      request.headers["Authorization"] = @auth_token unless token_expired?
    end

    schedule.clear
    schedule.every(1.minute) do
      logger.debug { "polling to check connectivity" }
      resp = get("/v1/public/info/")
      if resp.success?
        logger.debug { resp.body }
        get_all_leds
      end
    end
  end

  class FailureResponse
    include JSON::Serializable

    property detail : String
  end

  class AuthResponse
    include JSON::Serializable

    # Returned on success
    property access_token : String
    property refresh_token : String
    property token_type : String
  end

  def token_expired?
    @expired
  end

  def get_token
    return @auth_token unless token_expired?

    # attempt to use refresh token if one is available
    if refresh_token = @refresh_token
      response = post("/v1/oauth2/token",
        body: {
          grant_type:    "refresh_token",
          refresh_token: refresh_token,
        }.to_json
      )

      if response.success?
        resp = AuthResponse.from_json(response.body.not_nil!)
        @expired = false
        @auth_token = "#{resp.token_type} #{resp.access_token}"
        @refresh_token = resp.refresh_token
        return @auth_token
      else
        logger.debug { "refresh token request failed" }
      end
    end

    # Fall back to using the username and password
    response = post("/v1/oauth2/token",
      body: {
        grant_type: "password",
        username:   USERNAME,
        password:   @password,
      }.to_json
    )

    data = response.body.not_nil!

    if response.success?
      resp = AuthResponse.from_json(data)
      @expired = false
      @refresh_token = resp.refresh_token
      @auth_token = "#{resp.token_type} #{resp.access_token}"
    else
      resp = FailureResponse.from_json(data)
      raise "failed to obtain access token: #{resp.detail} (#{response.status})"
    end
  end

  @[Security(Level::Administrator)]
  def update_password(new_password : String)
    raise "password must be between 4 and 16 characters" unless new_password.size >= 4 && new_password.size <= 16
    query("POST", "/v1/user/password") do
      define_setting(:password, new_password)
    end
  end

  @[Security(Level::Administrator)]
  def wifi_scan
    query("GET", "/v1/wifi/scan_results") { |data| JSON.parse(data.not_nil!) }
  end

  enum AdvertiseMode
    LowLatency
    Balanced
    LowPower
  end

  @[Security(Level::Administrator)]
  def set_ibeacon(
    enabled : Bool,
    major : UInt16? = nil,
    minor : UInt16? = nil,
    uuid : String? = nil,
    advertise_mode : AdvertiseMode? = nil,
    power : Int8? = nil
  )
    query("POST", "/v1/net/beacon/ibeacon", {
      enabled:        enabled ? "enabled" : "disabled",
      major:          major,
      minor:          minor,
      uuid:           uuid,
      advertise_mode: advertise_mode.to_s.underscore,
      power:          power,
    }.to_json) { true }
  end

  def get_ibeacon
    query("GET", "/v1/net/beacon/ibeacon") { |data| JSON.parse(data.not_nil!) }
  end

  # https://github.com/google/eddystone/tree/master/eddystone-uid
  @[Security(Level::Administrator)]
  def set_eddystone_uid(
    enabled : Bool,
    namespace : String? = nil,
    instance : String? = nil,
    advertise_mode : AdvertiseMode? = nil,
    power : Int8? = nil
  )
    query("POST", "/v1/net/beacon/eddystone_uid", {
      enabled:        enabled ? "enabled" : "disabled",
      namespace:      namespace,
      instance:       instance,
      advertise_mode: advertise_mode.to_s.underscore,
      power:          power,
    }.to_json) { true }
  end

  def get_eddystone_uid
    query("GET", "/v1/net/beacon/eddystone_uid") { |data| JSON.parse(data.not_nil!) }
  end

  @[Security(Level::Administrator)]
  def set_eddystone_url(
    enabled : Bool,
    url : String? = nil,
    advertise_mode : AdvertiseMode? = nil,
    power : Int8? = nil
  )
    query("POST", "/v1/net/beacon/eddystone_url", {
      enabled:        enabled ? "enabled" : "disabled",
      url:            url,
      advertise_mode: advertise_mode.to_s.underscore,
      power:          power,
    }.to_json) { true }
  end

  def get_eddystone_url
    query("GET", "/v1/net/beacon/eddystone_url") { |data| JSON.parse(data.not_nil!) }
  end

  def device_info
    query("GET", "/v1/info/") { |data| JSON.parse(data.not_nil!) }
  end

  def settings
    query("GET", "/v1/settings") { |data| JSON.parse(data.not_nil!) }
  end

  @[Security(Level::Administrator)]
  def set_setting(key : String, value : String | JSON::Any)
    query("POST", "/v1/settings/#{key}", {
      value: value,
    }.to_json) { true }
  end

  @[Security(Level::Support)]
  def set_url(value : String)
    set_setting "content_url", value
  end

  def leds
    query("GET", "/v1/led") { |data| self[:leds] = NamedTuple(results: Array(String)).from_json(data.not_nil!)[:results] }
  end

  def get_led_state(name : String)
    query("GET", "/v1/led/#{name}") { |data| self[name] = JSON.parse(data.not_nil!) }
  end

  def get_all_leds
    query("GET", "/v1/led") do |data|
      leds = NamedTuple(results: Array(String)).from_json(data.not_nil!)[:results]
      self[:light_names] = leds
      leds.each { |name| get_led_state(name) }
      true
    end
  end

  @[Security(Level::Support)]
  def set_led_state(name : String, red : UInt8, green : UInt8, blue : UInt8)
    value = {
      red:   red,
      green: green,
      blue:  blue,
    }
    query("POST", "/v1/led/#{name}", value.to_json) { self[name] = value }
  end

  def set_all_leds(red : UInt8, green : UInt8, blue : UInt8)
    query("GET", "/v1/led") do |data|
      leds = NamedTuple(results: Array(String)).from_json(data.not_nil!)[:results]
      leds.each { |name| set_led_state(name, red, green, blue) }
      true
    end
  end

  private def query(
    method, path, body : ::HTTP::Client::BodyType = nil,
    params : Hash(String, String?) | URI::Params = URI::Params.new,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    **opts, &block : String -> _
  )
    queue(**opts) do |task|
      response = http(method, path, body, params, headers)

      if response.status.unauthorized?
        @expired = true
        get_token
        task.retry
      elsif response.success?
        task.success block.call(response.body)
      else
        begin
          resp = FailureResponse.from_json(response.body.not_nil!)
          task.abort "#{resp.detail} - #{response.status} (#{response.status_code})"
        rescue
          task.abort "unexpected response #{response.status} (#{response.status_code})\n#{response.body}"
        end
      end
    end
  end
end
