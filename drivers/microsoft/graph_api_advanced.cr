require "placeos-driver"
require "office365"

class Microsoft::GraphAPIAdvanced < PlaceOS::Driver
  descriptive_name "Direct Access to Microsoft Graph API"
  generic_name :MSGraphAPI

  uri_base "https://graph.microsoft.com/"

  default_settings({
    credentials: {
      tenant:        "",
      client_id:     "",
      client_secret: "",
    },

  })

  alias GraphParams = NamedTuple(
    tenant: String,
    client_id: String,
    client_secret: String,
  )

  def on_update
    credentials = setting(GraphParams, :credentials)
    @client = Office365::Client.new(**credentials)
  end

  private def get(path : String, query_params : URI::Params? = nil)
    @client.not_nil!.graph_request(
      @client.not_nil!.graph_http_request(
        request_method: "GET",
        path: path,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def get_request(path : String)
    get(path)
  end

  private def post(path : String, query_params : URI::Params? = nil, body : String? = nil)
    @client.not_nil!.graph_request(
      @client.not_nil!.graph_http_request(
        request_method: "POST",
        path: path,
        data: body,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def post_request(path : String)
    post(path)
  end

  private def put(path : String, query_params : URI::Params? = nil, body : String? = nil)
    @client.not_nil!.graph_request(
      @client.not_nil!.graph_http_request(
        request_method: "PUT",
        path: path,
        data: body,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def put_request(path : String)
    put(path)
  end

  def list_managed_devices(filter_device_name : String? = nil)
    query_params = filter_device_name ? URI::Params{"filter" => "deviceName eq #{filter_device_name}"} : nil
    response = get(
      "/v1.0/deviceManagement/managedDevices",
      query_params
    )
    response.body["value"]
  end

  def list_users_managed_devices(user_id : String)
    response = get(
      "/v1.0/users/#{user_id}/managedDevices"
    )
    response.body["value"]
  end
end
