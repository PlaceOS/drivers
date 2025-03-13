require "placeos-driver"
require "./cloud_xapi/ui_extensions"

class Cisco::Webex::Cloud < PlaceOS::Driver
  include CloudXAPI::UIExtensions

  # Discovery Information
  descriptive_name "Webex Cloud xAPI"
  generic_name :CloudXAPI

  uri_base "https://webexapis.com"

  default_settings({
    cisco_client_id:      "",
    cisco_client_secret:  "",
    cisco_target_orgid:   "",
    cisco_app_id:         "",
    cisco_personal_token: "",
  })

  getter! device_token : DeviceToken

  @cisco_client_id : String = ""
  @cisco_client_secret : String = ""
  @cisco_target_orgid : String = ""
  @cisco_app_id : String = ""
  @cisco_personal_token : String = ""

  def on_load
    on_update
    schedule.every(1.minute) { keep_token_refreshed }
  end

  def on_update
    @cisco_client_id = setting(String, :cisco_client_id)
    @cisco_client_secret = setting(String, :cisco_client_secret)
    @cisco_target_orgid = setting(String, :cisco_target_orgid)
    @cisco_app_id = setting(String, :cisco_app_id)
    @cisco_personal_token = setting(String, :cisco_personal_token)
    @device_token = setting?(DeviceToken, :cisco_token_pair) || @device_token
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

    headers = HTTP::Headers{
      "Authorization" => get_access_token,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    }
    response = get("/v1/xapi/status?#{query}", headers: headers)
    raise "failed to query status for device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def command(name : String, payload : String)
    headers = HTTP::Headers{
      "Authorization" => get_access_token,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    }
    response = post("/v1/xapi/command/#{name}", headers: headers, body: payload)
    raise "failed to execute command #{name}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  protected def get_access_token
    if device_token?
      return device_token.auth_token if 1.minute.from_now < device_token.expiry
      return refresh_token if 1.minute.from_now < device_token.refresh_expiry
    end

    body = {
      "clientId":     @cisco_client_id,
      "clientSecret": @cisco_client_secret,
      "targetOrgId":  @cisco_target_orgid,
    }.to_json

    headers = HTTP::Headers{
      "Authorization" => "Bearer #{@cisco_personal_token}",
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    }
    response = post("/v1/applications/#{@cisco_app_id}/token", headers: headers, body: body)
    raise "failed to retriee access token for client-id #{@cisco_client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    @device_token = DeviceToken.from_json(response.body)
    define_setting(:cisco_token_pair, device_token)
    device_token.auth_token
  end

  protected def refresh_token
    body = URI::Params.build do |form|
      form.add("grant_type", "refresh_token")
      form.add("client_id", @cisco_client_id)
      form.add("client_secret", @cisco_client_secret)
      form.add("refresh_token", device_token.refresh_token)
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }
    response = post("/v1/access_token", headers: headers, body: body)
    raise "failed to refresh access token for client-id #{@cisco_client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    @device_token = DeviceToken.from_json(response.body)
    define_setting(:cisco_token_pair, device_token)
    device_token.auth_token
  end

  protected def keep_token_refreshed : Nil
    return if @device_token.nil?
    refresh_token if 1.minute.from_now < device_token.refresh_expiry
  end
end
