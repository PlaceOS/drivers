require "placeos-driver"
require "jwt"

require "./p864_models"

class Optergy::P864 < PlaceOS::Driver
  # Discovery Information
  generic_name :BMS
  descriptive_name "Optergy P864 BMS"
  uri_base "https://bms.org.com"

  default_settings({
    username: "admin",
    password: "password",
  })

  @username : String = ""
  @password : String = ""

  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
  end

  def version
    response = get("/version", headers: auth_headers)
    NamedTuple(version: String).from_json(check response)[:version]
  end

  def config
    response = get("/api/device/config", headers: auth_headers)
    Config.from_json(check response)
  end

  TYPES = {"value", "input", "output"}

  {% begin %}
    {% for type in TYPES %}
      {% type_id = type.id %}
      {% url = "/api/a#{type.chars[0].id}/" %}

      def analog_{{ type.id }}s
        response = get({{url}}, headers: auth_headers)
        Array(AnalogValue).from_json(check response)
      end
    
      def analog_{{ type.id }}(instance : Int32)
        path = String.build do |str|
          str << {{url}}
          instance.to_s(str)
        end
        response = get(path, headers: auth_headers)
        AnalogValue.from_json(check response)
      end

      {% if type != "input" %}
        @[Security(Level::Administrator)]
        def write_analog_{{ type.id }}(instance : Int32, value : Float64, priority : Int32 = 8)
          path = String.build do |str|
            str << {{url}}
            instance.to_s(str)
          end
          response = post(path, headers: auth_headers, body: {
            value: value.to_s,
            arrayIndex: priority,
            property: "presentValue",
          }.to_json)
          AnalogValue.from_json(check response)
        end
      {% end %}
    {% end %}
  {% end %}

  {% begin %}
    {% for type in TYPES %}
      {% type_id = type.id %}
      {% url = "/api/b#{type.chars[0].id}/" %}

      def binary_{{ type.id }}s
        response = get({{url}}, headers: auth_headers)
        Array(BinaryValue).from_json(check response)
      end
    
      def binary_{{ type.id }}(instance : Int32)
        path = String.build do |str|
          str << {{url}}
          instance.to_s(str)
        end
        response = get(path, headers: auth_headers)
        BinaryValue.from_json(check response)
      end

      {% if type != "input" %}
        @[Security(Level::Administrator)]
        def write_binary_{{ type.id }}(instance : Int32, value : Bool, priority : Int32 = 8)
          path = String.build do |str|
            str << {{url}}
            instance.to_s(str)
          end
          response = post(path, headers: auth_headers, body: {
            value: value ? "Active" : "Inactive",
            arrayIndex: priority,
            property: "presentValue",
          }.to_json)
          BinaryValue.from_json(check response)
        end
      {% end %}
    {% end %}
  {% end %}

  @[Security(Level::Administrator)]
  def set_input_mode(instance : Int32, mode : String)
    response = post("/api/ai/#{instance}/mode", headers: auth_headers, body: {
      mode: mode,
    }.to_json)
    ModeResponse.from_json(check response)
  end

  # ==============
  # Authentication
  # ==============

  def token_expired?
    @auth_expiry < Time.utc
  end

  record TokenResponse, token : String do
    include JSON::Serializable
  end

  @[Security(Level::Administrator)]
  def get_token
    return @auth_token unless token_expired?

    response = post("/authorize", body: {
      username: @username,
      password: @password,
    }.to_json)

    body = response.body
    now = Time.utc
    logger.debug { "received login response: #{body}" }

    if response.success?
      set_connected_state true
      token = TokenResponse.from_json(body).token
      payload, header = JWT.decode(token, verify: false, validate: false)

      # time is relative in this JWT (non standard)
      issued = payload["iat"].as_i64
      expires = payload["exp"].as_i64
      expires_at = now + (expires - issued - 3).seconds

      @auth_expiry = expires_at
      @auth_token = "Bearer #{token}"
    else
      set_connected_state false
      logger.error { "authentication failed with HTTP #{response.status_code}" }
      raise "failed to obtain access token"
    end
  end

  @[Security(Level::Administrator)]
  def auth_headers
    HTTP::Headers{
      "Accept"        => "application/json",
      "Authorization" => get_token,
    }
  end

  macro check(response)
    %resp =  {{response}}
    logger.debug { "received: #{%resp.body}" }
    raise "error response: #{%resp.status} (#{%resp.status_code})\n#{%resp.body}" unless %resp.success?
    %resp.body
  end
end
