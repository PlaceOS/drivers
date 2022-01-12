require "placeos-driver"
require "./ws_api_models"

# docs: https://drive.google.com/file/d/1moo9NnFWukSf6fegxaZnSP5ShqSr_A03/view?usp=sharing

class SecureOS::RestApi < PlaceOS::Driver
  generic_name :SecureOS
  descriptive_name "SecureOS REST API"

  uri_base "ws://secureos.server:8888/"
  default_settings({
    shared_host:   true,
    rest_api_host: "http://172.16.1.120:8888",
    basic_auth:    {
      username: "srvc_acct",
      password: "password!",
    },
  })

  @rest_api_host : String = ""

  getter! basic_auth : NamedTuple(username: String, password: String)

  def on_load
    on_update
  end

  def on_update
    @rest_api_host = setting String, :rest_api_host
    @basic_auth = setting NamedTuple(username: String, password: String), :basic_auth
  end

  def connected
    host = setting?(Bool, :shared_host) ? config.uri.not_nil! : @rest_api_host
    client = HTTP::Client.new URI.parse(host)
    client.basic_auth **basic_auth
    response = client.get "#{@rest_api_host}/api/v1/ws_auth"
    if response.success?
      json_body = JSON.parse response.body
      token = json_body["data"]["token"].as_s

      send({type: :auth, token: token}.to_json, wait: false)
    else
      raise "Authentication failed"
    end

    schedule.every(30.seconds) { send({type: :get_server_time}.to_json, name: :server_time) }
  rescue error
    logger.warn(exception: error) { "Authentication failed" }
    disconnect
  end

  def disconnected
    schedule.clear
  end

  def subscribe_states(
    camera_id : String,
    camera_type : String = "CAM",
    states : Array(String) = ["attached", "armed", "alarmed"]
  )
    send({
      type: :subscribe,
      # id: 1234, # optional id used in error responses
      data: {
        add_rules: [
          {
            type:   camera_type,
            id:     camera_id,
            states: states,
            action: :STATE_CHANGED,
          },
        ],
      },
    }.to_json, wait: false)
  end

  def subscribe_events(
    camera_id : String,
    camera_type : String = "LPR_CAM",
    events : Array(String) = ["CAR_LP_RECOGNIZED"]
  )
    send({
      type: :subscribe,
      # id: 1234, # optional id used in error responses
      data: {
        add_rules: [
          {
            type:   camera_type,
            id:     camera_id,
            events: events,
            action: :EVENT,
          },
        ],
      },
    }.to_json, wait: false)
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "SecureOS sent: #{raw_json}" }

    type_check = JSON.parse(raw_json)["type"]?
    if type_check
      response = Response.from_json raw_json
      case response
      in StateWrapper
        self["camera_#{response.data.id}_states"] = response.data.states
      in EventWrapper
        self["camera_#{response.data.id}_action"] = response.data.action
        if parameters = response.data.parameters
          self["camera_#{response.data.id}"] = parameters
        else
          self["camera_#{response.data.id}"] = nil
          logger.warn { "No parameters in response" }
        end
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
