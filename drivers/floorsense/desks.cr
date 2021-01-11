require "uri"
require "jwt"
require "./models"

module Floorsense; end

# Documentation:
# https://apiguide.smartalock.com/
# https://documenter.getpostman.com/view/8843075/SVmwvctF?version=latest#3bfbb050-722d-4433-889a-8793fa90af9c

class Floorsense::Desks < PlaceOS::Driver
  # Discovery Information
  generic_name :Floorsense
  descriptive_name "Floorsense Desk Tracking"

  default_settings({
    username: "srvc_acct",
    password: "password!",
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

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    now = Time.utc
    @auth_expiry < now
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/restapi/login", body: "username=#{@username}&password=#{@password}", headers: {
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    })

    data = response.body.not_nil!
    logger.debug { "received login response #{data}" }

    if response.success?
      resp = AuthResponse.from_json(data)
      token = resp.info.not_nil!.token
      payload, _ = JWT.decode(token, verify: false, validate: false)
      @auth_expiry = (Time.unix payload["exp"].as_i64) - 5.minutes
      @auth_token = "Bearer #{token}"
    else
      case response.status_code
      when 401
        resp = AuthResponse.from_json(data)
        logger.warn { "#{resp.message} (#{resp.code})" }
      else
        logger.error { "authentication failed with HTTP #{response.status_code}" }
      end
      raise "failed to obtain access token"
    end
  end

  def floors
    token = get_token
    uri = "/restapi/floorplan-list"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      check_response DesksResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def desks(plan_id : String)
    token = get_token
    uri = "/restapi/floorplan-desk?planid=#{plan_id}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      check_response DesksResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def locate(key : String, controller_id : String? = nil)
    token = get_token
    uri = if controller_id
            "/restapi/user-locate?cid=#{controller_id}&key=#{URI.encode_www_form key}"
          else
            "/restapi/user-locate?name=#{URI.encode_www_form key}"
          end

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      resp = LocateResponse.from_json(response.body.not_nil!)
      # Select users where there is a desk key found
      check_response(resp).select(&.key)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  protected def check_response(resp)
    if resp.result
      resp.info.not_nil!
    else
      raise "bad response result (#{resp.code}) #{resp.message}"
    end
  end
end
