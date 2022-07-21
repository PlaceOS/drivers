require "placeos-driver"
require "xml"
require "json"
require "uri"

require "./fusion_models"

# Documentation: https://sdkcon78221.crestron.com/sdk/Fusion_APIs/Content/Topics/Default.htm

class Crestron::Fusion < PlaceOS::Driver
  descriptive_name "Crestron Fusion"
  generic_name :CrestronFusion
  description <<-DESC
    Crestron Fusion
  DESC

  default_settings({
    # Security level: 0 (No Security), 1 (Clear Text), 2 (Encrypted)
    security_level: 1,

    user_id:        "FUSION_USER_ID",

    # Should be the same as set in the Fusion configuration client
    api_pass_code:  "FUSION_API_PASS_CODE",

    # API Service URL, should be like http://FUSION_SERVER/RoomViewSE/APIService/
    service_url:    "http://FUSION_SERVER/RoomViewSE/APIService/",

    # xml or json
    content_type:   "json",
  })

  @security_level : Int32 = 1
  @user_id : String = ""
  @api_pass_code : String = ""
  @service_url : String = ""
  @content_type : String = ""

  # TODO: add handling of security level 1 and 2

  def on_load
    on_update
  end

  def on_update
    @security_level = setting(Int32, :security_level)
    @user_id = setting(String, :user_id)
    @api_pass_code = setting(String, :api_pass_code)
    @service_url = setting(String, :api_pass_code)
    @content_type = setting(String, :content_type)
  end

  def get_rooms(name : String?, node_id : String? = nil, page : Int32? = nil)
    params = URI::Params.new
    params["search"] = name if name
    params["node"] = node_id if node_id
    params["page"] = page if page

    response = perform_request("GET", "/Rooms", params)
    Array(Room).from_json(response.body)
  end

  def get_room(room_id : String)
    response = perform_request("GET", "/Rooms/#{room_id}")
    # @content_type == "xml" ? Room.from_xml(response_body) : Room.from_json(response_body)
    Room.from_json(response.body)
  end

  private def perform_request(method : String, path : String, params : URI::Params = URI::Params.new, body : String? = nil)
    if @security_level == 1
      params["auth"] = "#{@api_pass_code}%20#{@user_id}"
    end

    uri = URI.parse("@service_url/#{path}")
    uri.params = params

    headers = HTTP::Headers.new
    headers["Content-Type"] = @content_type
    headers["Accept"] = @content_type

    response = HTTP::Client.exec(method, uri, headers, body)
    if response.status_code == 200
      response
    else
      raise "Fusion API request failed. Status code: #{response.status_code}"
    end
  end  
end
