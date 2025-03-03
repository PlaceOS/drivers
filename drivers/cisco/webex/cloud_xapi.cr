require "placeos-driver"
require "./cloud_xapi/ui_extensions"

class Cisco::Webex::Cloud < PlaceOS::Driver
  include CloudXAPI::UIExtensions
  # Discovery Information
  descriptive_name "Webex Cloud xAPI"
  generic_name :CloudXAPI

  uri_base "https://webexapis.com"

  default_settings({
    cisco_client_id:     "",
    cisco_client_secret: "",
    cisco_scopes:        "spark:xapi_commands spark:xapi_statuses",
  })

  @credentials : String = ""
  getter! authoriation : Authorization
  getter! device_token : DeviceToken

  @cisco_client_id : String = ""
  @cisco_client_secret : String = ""
  @cisco_scopes : String = ""

  def on_update
    @cisco_client_id = setting(String, :cisco_client_id)
    @cisco_client_secret = setting(String, :cisco_client_secret)
    @cisco_scopes = setting?(String, :cisco_scopes) || "spark:xapi_commands spark:xapi_statuses"
    @credentials = Base64.strict_encode("#{@cisco_client_id}:#{@cisco_client_secret}")

    transport.before_request do |req|
      unless req.path.in?("/v1/device/authorize", "/v1/device/token", "/v1/device/access_token")
        access_token = get_access_token(@cisco_client_id, @cisco_client_secret)
        req.headers["Authorization"] = access_token
        req.headers["Content-Type"] = "application/json"
        req.headers["Accept"] = "application/json"
      end
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  def authorize : String
    @authoriation = authorize(@cisco_client_id, @cisco_scopes)
    authoriation.verification_uri_complete
  end

  def led_colour?(device_id : String)
    status(device_id, "UserInterface.LedControl.Color")
  end

  command({"UserInterface LedControl Color Set" => :led_colour}, color: Colour)

  def status(device_id : String, name : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
      form.add("name", name)
    end

    response = get("/v1/xapi/status?#{query}")
    raise "failed to query status for device #{device_id}, code #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  def command(name : String, payload : String)
    response = post("/v1/xapi/command/#{name}", body: payload)
    raise "failed to execute command #{name}, code #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # https://developer.webex.com/docs/login-with-webex#getting-an-access-token-with-device-grant-flow
  protected def get_access_token(client_id, client_secret)
    raise "complete authorization process by visiting the url returned via driver :authorize method" if @authoriation.nil?

    if device_token?
      return device_token.auth_token if 1.minute.from_now < device_token.expiry
      return refresh_token(client_id, client_secret) if 1.minute.from_now < device_token.refresh_expiry
    end

    # Minimum amount of time in seconds we should wait before polling device token endpoint
    sleep authoriation.interval.seconds

    body = URI::Params.build do |form|
      form.add("client_id", client_id)
      form.add("device_code", authoriation.device_code)
      form.add("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
    end

    headers = HTTP::Headers{
      "Authorization" => "Basic #{@credentials}",
      "Content-Type"  => "application/x-www-form-urlencoded",
      "Accept"        => "application/json",
    }
    response = post("/v1/device/token", headers: headers, body: body)
    raise "failed to get device access token for client-id #{client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    @device_token = DeviceToken.from_json(response.body)
    device_token.auth_token
  end

  protected def authorize(client_id : String, scope : String) : Authorization
    body = URI::Params.build do |form|
      form.add("client_id", client_id)
      form.add("scope", scope)
    end
    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }
    response = post("/v1/device/authorize", headers: headers, body: body)
    raise "failed to authorize client-id #{client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    Authorization.from_json(response.body)
  end

  protected def refresh_token(client_id : String, client_secret : String)
    body = URI::Params.build do |form|
      form.add("grant_type", "refresh_token")
      form.add("client_id", client_id)
      form.add("client_secret", client_secret)
      form.add("refresh_token", device_token.refresh_token)
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }
    response = post("/v1/device/access_token", headers: headers, body: body)
    raise "failed to refresh device access token for client-id #{client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    @device_token = DeviceToken.from_json(response.body)
    device_token.auth_token
  end
end
