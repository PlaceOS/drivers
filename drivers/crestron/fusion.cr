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

    user_id:        "Fusion user id",

    # Should be the same as set in the Fusion configuration client
    api_pass_code:  "",

    # API Service URL, should be like http://FUSION_SERVER/RoomViewSE/APIService/
    service_url:    "http://FUSION_SERVER/RoomViewSE/APIService/",

    # xml or json
    content_type:   "xml",
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

    uri = URI.parse(@service_url)
    uri.path = "#{uri.path}/Rooms"
    uri.query_params = params

    headers = HTTP::Headers.new
    headers["Content-Type"] = @content_type
    headers["Accept"] = @content_type

    client = HTTP::Client.new(uri: uri)
    response = client.get(uri, headers)
    if response.status_code == 200
      @content_type == "xml" ? Room.from_xml(response.body) : Room.from_json(response.body)
    else
      raise "Failed to get rooms from Fusion API. Status code: #{response.status_code}"
    end
  end

  def get_room(room_id : String)
    uri = URI.parse(@service_url)
    uri.path = "#{uri.path}/Rooms/#{room_id}"

    headers = HTTP::Headers.new
    headers["Content-Type"] = @content_type
    headers["Accept"] = @content_type

    client = HTTP::Client.new(uri: uri)
    response = client.get(uri, headers)
    if response.status_code == 200
      @content_type == "xml" ? Room.from_xml(response.body) : Room.from_json(response.body)
    else
      raise "Failed to get room from Fusion API. Status code: #{response.status_code}"
    end
  end

  # private def perform_request(path : String, params : URI::Params? = nil)
  #   uri = URI.parse(@service_url)
  #   uri.path = "#{uri.path}/#{path}"

  #   headers = HTTP::Headers.new
  #   headers["Content-Type"] = @content_type
  #   headers["Accept"] = @content_type

  #   client = HTTP::Client.new(uri: uri)
  #   response = client.get(uri, headers)
  #   if response.status_code == 200
  #     @content_type == "xml" ? Room.from_xml(response.body) : Room.from_json(response.body)
  #   else
  #     raise "Failed to get room from Fusion API. Status code: #{response.status_code}"
  #   end
  # end
end
