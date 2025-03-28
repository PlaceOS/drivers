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
    debug_payload:        false,
  })

  getter! device_token : DeviceToken

  @cisco_client_id : String = ""
  @cisco_client_secret : String = ""
  @cisco_target_orgid : String = ""
  @cisco_app_id : String = ""
  @cisco_personal_token : String = ""
  @debug_payload : Bool = false

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
    @debug_payload = setting?(Bool, :debug_payload) || false

    @device_token = setting?(DeviceToken, :cisco_token_pair) || @device_token
  end

  def led_mode?(device_id : String)
    config?(device_id, "UserInterface.LedControl.Mode")
  end

  def led_mode(device_id : String, value : String)
    value = value.downcase.capitalize
    config("UserInterface.LedControl.Mode", device_id, value)
  end

  def led_colour?(device_id : String)
    status(device_id, "UserInterface.LedControl.Color")
  end

  command({"UserInterface LedControl Color Set" => :led_colour}, color: Colour)

  def list_workspaces(org_id : String? = nil, location_id : String? = nil, workspace_location_id : String? = nil, floor_id : String? = nil,
                      display_name : String? = nil, capacity : Int32? = nil, workspace_type : String? = nil, start : Int32? = nil, max : Int32? = nil,
                      calling : String? = nil, supported_devices : String? = nil, calendar : String? = nil, device_hosted_meetings_enabled : Bool? = nil,
                      device_platform : String? = nil, health_level : String? = nil)
    params = URI::Params.build do |form|
      form.add("orgId", org_id.to_s) if org_id
      form.add("locationId", location_id.to_s) if location_id
      form.add("workspaceLocationId", workspace_location_id.to_s) if workspace_location_id
      form.add("floorId", floor_id.to_s) if floor_id
      form.add("displayName", display_name.to_s) if display_name
      form.add("capacity", capacity.to_s) if capacity
      form.add("type", workspace_type.to_s) if workspace_type
      form.add("start", start.to_s) if start
      form.add("max", max.to_s) if max
      form.add("calling", calling.to_s) if calling
      form.add("supportedDevices", supported_devices.to_s) if supported_devices
      form.add("calendar", calendar.to_s) if calendar
      form.add("deviceHostedMeetingsEnabled", device_hosted_meetings_enabled.to_s) if device_hosted_meetings_enabled
      form.add("devicePlatform", device_platform.to_s) if device_platform
      form.add("healthLevel", health_level.to_s) if health_level
    end

    query = params.empty? ? nil : params.to_s
    api_get("/v1/workspaces", query)
  end

  def workspace_details(workspace_id : String)
    api_get("/v1/workspaces/#{workspace_id}")
  end

  def list_devices(max : Int32? = nil, start : Int32? = nil, display_name : String? = nil, person_id : String? = nil, workspace_id : String? = nil,
                   org_id : String? = nil, connection_status : String? = nil, product : String? = nil, device_type : String? = nil, serial : String? = nil,
                   tag : String? = nil, software : String? = nil, upgrade_channel : String? = nil, error_code : String? = nil, capability : String? = nil,
                   permission : String? = nil, location_id : String? = nil, workspace_location_id : String? = nil, mac : String? = nil, device_platform : String? = nil)
    params = URI::Params.build do |form|
      form.add("max", max.to_s) if max
      form.add("start", start.to_s) if start
      form.add("displayName", display_name.to_s) if display_name

      form.add("personId", person_id.to_s) if person_id
      form.add("workspaceId", workspace_id.to_s) if workspace_id
      form.add("orgId", org_id.to_s) if org_id
      form.add("connectionStatus", connection_status.to_s) if connection_status
      form.add("product", product.to_s) if product
      form.add("type", device_type.to_s) if device_type
      form.add("tag", tag.to_s) if tag
      form.add("serial", serial.to_s) if serial
      form.add("software", software.to_s) if software
      form.add("upgradeChannel", upgrade_channel.to_s) if upgrade_channel
      form.add("errorCode", error_code.to_s) if error_code
      form.add("capability", capability.to_s) if capability
      form.add("permission", permission.to_s) if permission
      form.add("locationId", location_id.to_s) if location_id
      form.add("workspaceLocationId", workspace_location_id.to_s) if workspace_location_id
      form.add("mac", mac.to_s) if mac
      form.add("devicePlatform", device_platform.to_s) if device_platform
    end
    query = params.empty? ? nil : params.to_s
    api_get("/v1/devices", query)
  end

  def device_details(device_id : String, org_id : String? = nil)
    params = URI::Params.build do |form|
      form.add("orgId", org_id.to_s) if org_id
    end

    query = params.empty? ? nil : params.to_s
    api_get("/v1/devices/#{device_id}", query)
  end

  def status(device_id : String, name : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
      form.add("name", name)
    end

    headers = get_headers
    logger.debug { {msg: "Status HTTP Data:", headers: headers.to_json, query: query.to_s} } if @debug_payload

    response = get("/v1/xapi/status?#{query}", headers: headers)
    raise "failed to query status for device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def command(name : String, payload : String)
    headers = get_headers
    logger.debug { {msg: "Command HTTP Data:", headers: headers.to_json, command: name, payload: payload} } if @debug_payload

    response = post("/v1/xapi/command/#{name}", headers: headers, body: payload)
    raise "failed to execute command #{name}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def api_get(resource : String, query : String? = nil)
    headers = get_headers
    logger.debug { {msg: "GET #{resource}:", headers: headers.to_json, query: query.to_s} } if @debug_payload
    uri = query.presence ? resource + "?#{query}" : resource
    response = get(uri, headers: headers)
    raise "failed to get #{resource}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def config?(device_id : String, name : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
      form.add("key", name)
    end

    headers = get_headers
    logger.debug { {msg: "Status HTTP Data:", headers: headers.to_json, query: query.to_s} } if @debug_payload

    response = get("/v1/deviceConfigurations?#{query}", headers: headers)
    raise "failed to query configuration for device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def config(name : String, device_id : String, value : String)
    body = {
      "op"    => "replace",
      "path"  => "#{name}/sources/configured/value",
      "value" => value,
    }

    config(device_id, body.to_json)
  end

  def config(device_id : String, payload : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
    end

    headers = get_headers("application/json-patch+json")
    logger.debug { {msg: "Config HTTP Data:", headers: headers.to_json, query: query, payload: payload} } if @debug_payload

    response = patch("/v1/deviceConfigurations?#{query}", headers: headers, body: payload)
    raise "failed to patch config on device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  protected def get_access_token
    if device_token?
      logger.debug { {msg: "Access Token expiry", expiry: device_token.expiry} } if @debug_payload
      return device_token.auth_token if 1.minute.from_now <= device_token.expiry
      logger.debug { {msg: "Access Token expiring, refreshing token", token_expiry: device_token.expiry, refresh_expiry: device_token.refresh_expiry} } if @debug_payload
      return refresh_token if 1.minute.from_now <= device_token.refresh_expiry
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
    refresh_token if 1.minute.from_now >= device_token.refresh_expiry
  end

  private def get_headers(content_type : String = "application/json")
    HTTP::Headers{
      "Authorization" => get_access_token,
      "Content-Type"  => content_type,
      "Accept"        => "application/json",
    }
  end
end
