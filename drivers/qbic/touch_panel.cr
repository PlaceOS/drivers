require "uri"

module Qbic; end

class Qbic::TouchPanel < PlaceOS::Driver
  descriptive_name "Qbic Touch Panel"
  generic_name :Display

  default_settings({
    username: "admin",
    password: "12345678",
  })

  @username : String = ""
  @password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @username = URI.encode_www_form setting(String, :username)
    @password = URI.encode_www_form setting(String, :password)
  end

  class AuthResponse
    include JSON::Serializable

    # Returned on success
    property access_token : String
    property refresh_token : String
    property token_type : String

    # Returned on failure
    property detail : String?
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    now = Time.utc
    @auth_expiry < now
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/v1/oauth2/token",
      body: {
        "grant_type" => "password",
        "username" => @username,
        "password" => @password
      }.to_json,
      headers: {
        "Content-Type" => "application/json"
      }
    )

    data = response.body.not_nil!
    logger.debug { "received login response #{data}" }

    if response.success?
      resp = AuthResponse.from_json(data)
      logger.debug { "resp" }
      logger.debug { resp.inspect }
      @auth_token = "#{resp.token_type} #{resp.access_token}"
    else
      case response.status_code
      when 400
        resp = AuthResponse.from_json(data)
        logger.warn { resp.detail }
      else
        logger.error { "authentication failed with HTTP #{response.status_code}" }
      end
      raise "failed to obtain access token"
    end
  end
end
