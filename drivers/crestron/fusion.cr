require "placeos-driver"
require "xml"
require "json"
require "uri"

# TODO: add handling of security level 2
# TODO: parse returend results into models
#
# Documentation: https://sdkcon78221.crestron.com/sdk/Fusion_APIs/Content/Topics/Default.htm
class Crestron::Fusion < PlaceOS::Driver
  descriptive_name "Crestron Fusion"
  generic_name :CrestronFusion
  description <<-DESC
    Crestron Fusion
  DESC

  uri_base "https://fusion.myorg.com/fusion/apiservice/"

  default_settings({
    # Security level: 0 (No Security), 1 (Clear Text), 2 (Encrypted)
    security_level: 1,

    user_id: "FUSION_USER_ID",

    # Should be the same as set in the Fusion configuration client
    api_pass_code: "FUSION_API_PASS_CODE",

    # xml or json
    content_type: "json",

    # uses old ciphers
    https_insecure: true,
  })

  @security_level : Int32 = 1
  @user_id : String = ""
  @api_pass_code : String = ""
  @content_type : String = ""

  def on_load
    on_update
  end

  def on_update
    @security_level = setting(Int32, :security_level)
    @user_id = setting(String, :user_id)
    @api_pass_code = setting(String, :api_pass_code)
    @content_type = "application/" + setting(String, :content_type)
  end

  ###########
  # Actions #
  ###########

  def get_actions(name : String?, room_id : String? = nil, page : Int32? = nil)
    params = URI::Params.new
    params["search"] = name if name
    params["room"] = room_id if room_id
    params["page"] = page.to_s if page

    response = perform_request("GET", "/actions", params)
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  def get_action(action_id : String)
    response = perform_request("GET", "/actions/#{action_id}")
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  def send_action(action_id : String?, room_id : String? = nil, node_id : String? = nil)
    params = URI::Params.new
    params["room"] = room_id if room_id
    params["node"] = node_id if node_id

    path = if (id = action_id) && !id.empty?
             "/actions/#{id}"
           else
             "/actions"
           end

    response = perform_request("POST", path, params)
    JSON.parse(response.body)
  end

  ##########
  # Alerts #
  ##########

  # Severity should be in the range 1-4
  def get_alerts(node_ids : Array(String)? = nil, room_ids : Array(String)? = nil, start_time : String? = nil, end_time : String? = nil, severity : Int32? = nil, active_alerts : Bool = true)
    params = URI::Params.new
    params["nodes"] = node_ids.join(',') if node_ids
    params["rooms"] = room_ids.join(',') if room_ids
    params["start"] = start_time if start_time
    params["end"] = end_time if end_time
    params["severity"] = severity.to_s if severity
    params["activeAlerts"] = active_alerts.to_s if active_alerts

    response = perform_request("GET", "/rooms", params)
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  #########
  # Rooms #
  #########

  def get_rooms(name : String?, node_id : String? = nil, page : Int32? = nil)
    params = URI::Params.new
    params["search"] = name if name
    params["node"] = node_id if node_id
    params["page"] = page.to_s if page

    response = perform_request("GET", "/rooms", params)
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  def get_room(room_id : String)
    response = perform_request("GET", "/rooms/#{room_id}")
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  #################
  # Signal Values #
  #################

  def get_signal_values(symbol_id : String)
    response = perform_request("GET", "/signalvalues/#{symbol_id}")
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  def get_signal_value(symbol_id : String, attribute_id : String)
    response = perform_request("GET", "/signalvalues/#{symbol_id}/#{attribute_id}")
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  def put_signal_value(symbol_id : String, attribute_id : String, value : String)
    params = URI::Params.new
    params["value"] = value

    response = perform_request("PUT", "/signalvalues/#{symbol_id}/#{attribute_id}", params)
    @content_type == "xml" ? XML.parse(response.body) : JSON.parse(response.body)
  end

  ###########
  # Helpers #
  ###########

  private def perform_request(method : String, path : String, params : URI::Params = URI::Params.new, body : String? = nil)
    if @security_level == 1
      params["auth"] = "#{@api_pass_code} #{@user_id}"
    elsif @security_level == 2
      params["auth"] = encrypted_token
    end

    headers = HTTP::Headers.new
    headers["Content-Type"] = @content_type
    headers["Accept"] = @content_type

    response = http(method, path, body, params, headers)
    if response.status_code == 200
      response
    else
      raise "Fusion API request failed. Status code: #{response.status_code}"
    end
  end

  private def encrypted_token
    # TODO: encrypt this
    # "#{Time.utc.to_rfc3339} #{@user_id}"
    raise "Fusion API security level 2 not supported"
  end
end
