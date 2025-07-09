require "placeos-driver"
require "./cloud_xapi/ui_extensions"
require "./workspace/workspace"

class Cisco::Webex::WorkspaceXApi < PlaceOS::Driver
  include CloudXAPI::UIExtensions

  # Discovery Information
  descriptive_name "Webex Cloud xAPI via Workspace Integration"
  generic_name :WebxWorkspaceXApi

  uri_base "https://webexapis.com"

  default_settings({
    cisco_client_id:         "",
    cisco_client_secret:     "",
    cisco_provisional_token: "",
    debug_payload:           false,
  })

  getter! workspace_integration : WebxWorkspace::WorkspaceIntegration

  alias ProxyConfig = NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?)
  @cisco_client_id : String = ""
  @cisco_client_secret : String = ""
  @cisco_provisional_token : String = ""
  @proxy_config : ProxyConfig? = nil
  @debug_payload : Bool = false

  def on_load
    on_update
    schedule.every(1.minute) { keep_token_refreshed }
  end

  def on_update
    @cisco_client_id = setting(String, :cisco_client_id)
    @cisco_client_secret = setting(String, :cisco_client_secret)
    @cisco_provisional_token = setting(String, :cisco_provisional_token)
    @proxy_config = setting?(ProxyConfig, :proxy)
    @debug_payload = setting?(Bool, :debug_payload) || false

    if !workspace_integration? && !@cisco_client_id.blank? && !@cisco_client_secret.blank? && !@cisco_provisional_token.blank?
      @workspace_integration = WebxWorkspace::WorkspaceIntegration.new(@cisco_client_id, @cisco_client_secret, @proxy_config)
    end

    if (workspace_integration? && !workspace_integration.initialized?) && (device_token = setting?(DeviceToken, :cisco_token_pair))
      workspace_integration.update_auth_tokens(device_token)
      queue_url = setting(String, :cisco_queue_poll_url)
      workspace_integration.queue_url = queue_url
    end
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

  def status(device_id : String, name : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
      form.add("name", name)
    end
    hdrs = self.headers
    logger.debug { {msg: "Status HTTP Data:", headers: hdrs.to_json, query: query.to_s} } if @debug_payload

    response = get("/v1/xapi/status?#{query}", headers: hdrs)
    raise "failed to query status for device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def command(name : String, payload : String)
    hdrs = self.headers
    logger.debug { {msg: "Command HTTP Data:", headers: hdrs.to_json, command: name, payload: payload} } if @debug_payload

    response = post("/v1/xapi/command/#{name}", headers: hdrs, body: payload)
    raise "failed to execute command #{name}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def config?(device_id : String, name : String)
    query = URI::Params.build do |form|
      form.add("deviceId", device_id)
      form.add("key", name)
    end

    hdrs = self.headers
    logger.debug { {msg: "Status HTTP Data:", headers: hdrs.to_json, query: query.to_s} } if @debug_payload

    response = get("/v1/deviceConfigurations?#{query}", headers: hdrs)
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
    hdrs = self.headers
    logger.debug { {msg: "Config HTTP Data:", headers: hdrs.to_json, query: query, payload: payload} } if @debug_payload

    response = patch("/v1/deviceConfigurations?#{query}", headers: hdrs, body: payload)
    raise "failed to patch config on device #{device_id}, code #{response.status_code}, body: #{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  protected def consume_messages(messages : Array(WebxWorkspace::Message))
    messages.select(WebxWorkspace::StatusMessage).select(WebxWorkspace::EventsMessage).map do |message|
      logger.debug { {message: "Polled #{message.type} message", polled: message.to_json} }
    end
  end

  protected def headers
    @workspace_integration = WebxWorkspace::WorkspaceIntegration.new(@cisco_client_id, @cisco_client_secret) unless workspace_integration?
    unless workspace_integration.initialized?
      workspace_integration.init_with_queue(@cisco_provisional_token)
      define_setting(:cisco_token_pair, workspace_integration.oauth_tokens)
      define_setting(:cisco_queue_poll_url, workspace_integration.queue_url)
      queue = workspace_integration.queue_poller(&->consume_messages(Array(WebxWorkspace::Message)))
      queue.start
    end
    workspace_integration.headers
  end

  protected def keep_token_refreshed : Nil
    return unless workspace_integration.initialized?

    if device_token = workspace_integration.keep_token_refreshed
      define_setting(:cisco_token_pair, device_token)
    end
  end
end
