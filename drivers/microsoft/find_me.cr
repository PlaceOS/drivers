module Microsoft; end

require "ntlm"
require "./find_me_models"

class Microsoft::FindMe < PlaceOS::Driver
  # include Interface::Locatable

  # Discovery Information
  uri_base "https://findme.companyname.com"
  descriptive_name "Microsoft FindMe Service"
  generic_name :FindMe

  def on_load
    on_update
  end

  @username : String = ""
  @password : String = ""
  @domain : String = ""
  @auth_token : String = ""

  def on_update
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
    @domain = setting?(String, :domain) || ""
  end

  # Makes requests and handles NTLM authentication
  protected def make_request(
    method, path, body : ::HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new
  ) : String
    headers["Authorization"] = @auth_token unless @auth_token.empty?
    response = http(method, path, body, params, headers)

    if response.status_code == 401 && response.headers["WWW-Authenticate"]?
      supported = response.headers.get("WWW-Authenticate")
      raise "doesn't support NTLM auth: #{supported}" unless supported.includes?("NTLM")

      # Negotiate NTLM
      headers["Authorization"] = NTLM.negotiate_http(@domain)
      response = http(method, path, body, params, headers)

      # Extract the challenge
      raise "unexpected response #{response.status_code}" unless response.status_code == 401 && response.headers["WWW-Authenticate"]?
      challenge = response.headers["WWW-Authenticate"]

      # Authenticate the client
      @auth_token = NTLM.authenticate_http(challenge, @username, @password)
      headers["Authorization"] = @auth_token
      response = http(method, path, body, params, headers)
    end

    raise "request #{path} failed with status: #{response.status_code}" unless response.success?

    response.body
  end

  def levels
    data = make_request("GET", "/FindMeService/api/MeetingRooms/BuildingLevelsWithMeetingRooms")
    logger.debug { "levels request returned: #{data}" }

    levels = Array(Microsoft::Level).from_json(data)
    buildings = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
    levels.each { |level| buildings[level.building] << level.name }

    buildings
  end

  def user_details(usernames : String | Array(String))
    users = usernames.is_a?(String) ? [usernames] : usernames
    data = make_request("GET", "/FindMeService/api/ObjectLocation/Users/#{users.join(",")}")

    logger.debug { "user details request returned #{data}" }

    Array(Microsoft::Location).from_json(data).reject{ |loc| loc.status == "NoData" }
  end

  def users_on(building : String, level : String)
    # Same response as above with or without ExtendedUserData
    uri = "/FindMeService/api/ObjectLocation/Level/#{building}/#{level}"
    # uri += "?getExtendedData=true" if extended_data

    data = make_request("GET", uri)

    begin
      Array(Microsoft::Location).from_json(data).reject{ |loc| {"NoRecentData", "NoData"}.includes?(loc.status) }
    rescue error
      logger.debug { "failed to parse location data\n#{data}" }
      raise error
    end
  end
end
