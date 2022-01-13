require "placeos-driver"
require "./ws_api_models"

# docs: https://drive.google.com/file/d/1moo9NnFWukSf6fegxaZnSP5ShqSr_A03/view?usp=sharing

class SecureOS::WsApi < PlaceOS::Driver
  generic_name :SecureOS
  descriptive_name "SecureOS WebSocket API"

  uri_base "ws://secureos.server:8888/"
  default_settings({
    shared_host:   true,
    rest_api_host: "http://172.16.1.120:8888",
    basic_auth:    {
      username: "srvc_acct",
      password: "password!",
    },
    camera_states: [StateType::Attached, StateType::Armed, StateType::Alarmed],
    camera_events: [] of String,
  })

  @rest_api_host : String = ""
  @camera_list : Array(Camera) = [] of Camera
  @camera_states : Array(StateType) = [] of StateType
  @camera_events : Array(String) = [] of String

  getter! basic_auth : NamedTuple(username: String, password: String)

  def on_load
    on_update
  end

  def on_update
    @rest_api_host = setting String, :rest_api_host
    @basic_auth = setting NamedTuple(username: String, password: String), :basic_auth
    @camera_states = setting Array(StateType), :camera_states
    @camera_events = setting Array(String), :camera_events
  end

  def connected
    host = setting?(Bool, :shared_host) ? config.uri.not_nil! : @rest_api_host
    client = HTTP::Client.new URI.parse(host)
    client.basic_auth **basic_auth
    response = client.get "#{@rest_api_host}/api/v1/ws_auth"
    if response.success?
      auth = AuthResponse.from_json response.body
      send({type: :auth, token: auth.data.token}.to_json, wait: false)
    else
      raise "Authentication failed"
    end

    schedule.every(30.seconds) { send({type: :get_server_time}.to_json, name: :server_time) }
    schedule.every(5.minutes, immediate: true) do
      camera_list
      subscribe_all
    end
  rescue error
    logger.warn(exception: error) { "Authentication failed" }
    disconnect
  end

  def disconnected
    schedule.clear
  end

  private def subscribe_all
    states = @camera_states.empty? ? nil : @camera_states
    events = @camera_events.empty? ? nil : @camera_events
    rules = [] of SubscribeRule

    @camera_list.each do |camera|
      rules << SubscribeRule.new(
        type: camera.type,
        id: camera.id,
        action: :STATE_CHANGED,
        states: states,
      )
      rules << SubscribeRule.new(
        type: camera.type,
        id: camera.id,
        action: :EVENT,
        events: events,
      )
    end

    return if rules.empty?

    send({
      type: :subscribe,
      # id: 1234, # optional id used in error responses
      data: {
        add_rules: rules,
      },
    }.to_json, wait: false)
  end

  private def camera_list
    host = setting?(Bool, :shared_host) ? config.uri.not_nil! : @rest_api_host
    client = HTTP::Client.new URI.parse(host)
    client.basic_auth **basic_auth
    response = client.get "#{@rest_api_host}/api/v1/cameras"
    if response
      json_response = RestResponse.from_json response.body
      self["camera_list"] = @camera_list = json_response.data
    else
      logger.warn { "Failed to get camera list" }
    end
  rescue error
    logger.warn(exception: error) { "Failed to get camera list" }
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "SecureOS sent: #{raw_json}" }

    type_check = JSON.parse(raw_json)["type"]?
    if type_check
      response = Response.from_json raw_json
      case response
      in StateWrapper
        self["camera_#{response.data.id}_states"] = response.data
      in EventWrapper
        self["camera_#{response.data.id}"] = response.data
      in ErrorWrapper
        logger.warn { "SecureOS error: #{response.data}" }
        if response.data.error.in?({"INVALID_AUTH_TOKEN", "UNAUTHORIZED"})
          disconnect
        else
          self["last_error"] = response.data
        end
      in Response
      end
    end

    task.try &.success
  end
end
