require "placeos-driver"
require "./models"

class HPE::ANW::Aruba < PlaceOS::Driver
  # Discovery Information
  descriptive_name "HPE Aruba Networking Central"
  generic_name :HPEAruba

  uri_base "https://api-ap.central.arubanetworks.com"

  default_settings({
    client_id:      "",
    client_secret:  "",
    customer_id:    "",
    username:       "",
    password:       "",
    gateway_domain: "https://api-ap.central.arubanetworks.com",
    debug_payload:  false,
  })

  getter! auth_token : Model::AuthToken

  @client_id : String = ""
  @client_secret : String = ""
  @username : String = ""
  @password : String = ""
  @customer_id : String = ""
  @debug_payload : Bool = false

  def on_load
    on_update
    schedule.every(1.minute) { keep_token_refreshed }
  end

  def on_update
    @client_id = setting(String, :client_id)
    @client_secret = setting(String, :client_secret)
    @customer_id = setting(String, :customer_id)
    @username = setting(String, :username)
    @password = setting(String, :password)
    @uri_base = setting?(String, :gateway_domain) || "https://api-ap.central.arubanetworks.com"
    @debug_payload = setting?(Bool, :debug_payload) || false

    @auth_token = setting?(Model::AuthToken, :aruba_token_pair) || @auth_token
  end

  # https://developer.arubanetworks.com/new-hpe-anw-central/reference/listclientlocationsforapi
  def wifi_locations(offset : Int32 = 0, limit : Int32 = 100, start_query_time : Time? = nil, site_id : String? = nil,
                     building_id : String? = nil, floor_id : String? = nil, associated : Bool? = nil, connected : Bool? = nil,
                     last_connect_client_mac_address : String? = nil) : Model::WifiClientLocations
    query = URI::Params.build do |form|
      limit = limit > 1000 ? 1000 : limit
      if mac_address = last_connect_client_mac_address
        form.add("last-connect-client-mac-address", mac_address)
      else
        hash = {"siteId" => site_id, "buildingId" => building_id, "floorId" => floor_id, "associated" => associated, "connected" => connected}.compact
        raise ArgumentError.new("site_id is mandatory when other params are set") if hash.size > 0 && !hash.has_key?("siteId")
        filter = [] of String
        hash.each do |key, value|
          filter << "#{key} eq #{value}"
        end
        unless filter.empty?
          form.add("latest-location-per-clien", "1")
          form.add("filter", filter.join(" and "))
        end
      end

      form.add("limit", limit.to_s)
      form.add("offset", offset.to_s) unless offset == 0

      if query_time = start_query_time
        form.add("start-query-time", query_time.to_unix_ms.to_s)
      end
    end

    headers = HTTP::Headers{
      "Authorization" => access_token,
      "Content-Type"  => "application/json",
    }
    logger.debug { {msg: "Get Wifi client locations HTTP Data:", headers: headers.to_json, query_params: query.to_s} } if @debug_payload

    response = get("/network-monitoring/v1alpha1/wifi-clients-locations?#{query}", headers: headers)
    raise "failed to obtain wifi client locations , response code #{response.status_code}, body: #{response.body}" unless response.success?
    Model::WifiClientLocations.from_json(response.body)
  end

  # https://developer.arubanetworks.com/hpe-aruba-networking-central/reference/get_visualrf-api-v1-client-location-macaddr
  def client_location(mac_address : String, offset : Int32 = 0, limit : Int32 = 100, units : Model::MeasurementUnit = Model::MeasurementUnit::FEET) : Model::ClientLocation
    query = URI::Params.build do |form|
      form.add("offset", offset.to_s)
      form.add("limit", limit.to_s)
      form.add("units", units.to_s)
    end

    headers = HTTP::Headers{
      "Authorization" => access_token,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    }
    logger.debug { {msg: "Get Wifi client locations HTTP Data:", headers: headers.to_json, query_params: query.to_s} } if @debug_payload

    response = get("visualrf_api/v1/client_location/#{mac_address}?#{query}", headers: headers)
    raise "failed to obtain client wifi location , response code #{response.status_code}, body: #{response.body}" unless response.success?
    Model::ClientLocation.from_json(response.body, root: "location")
  end

  protected def access_token
    unless auth_token?
      tokens = authenticate
      code = authorize(*tokens)
      @auth_token = accquire_token(code)
      define_setting(:aruba_token_pair, auth_token)
    end
    refresh_token if 1.minute.from_now >= auth_token.expiry
    auth_token.token
  end

  protected def authenticate
    logger.debug { "STEP 1 - Login and Obtain CSRF Token and Session id" } if @debug_payload

    query = URI::Params.build do |form|
      form.add("client_id", @client_id)
    end

    payload = {
      "username" => @username,
      "password" => @password,
    }.to_json

    headers = HTTP::Headers{
      "Content-Type" => "application/json",
    }
    logger.debug { {msg: "Authenticate HTTP Data:", headers: headers.to_json, query_params: query.to_s, payload: payload} } if @debug_payload

    response = post("/oauth2/authorize/central/api/login?#{query}", headers: headers, body: payload)
    raise "failed to authenticate user #{@username}, response code #{response.status_code}, body: #{response.body}" unless response.success?
    raise "No CSRF and Session cookes returned from gateway" unless response.headers.has_key?("Set-Cookie")

    cookies = response.headers["Set-Cookie"].split(";").reject(&.empty?).map(&.split('=')).to_h
    csrftoken = if (cookie = cookies["csrftoken"]?)
                  cookie.split(";").first
                else
                  raise "crsftoken cookie not found in authenticate user response"
                end
    session = if (cookie = cookies["session"]?)
                cookie.split(";").first
              else
                raise "session cookie not found in authenticate user response"
              end
    {csrftoken, session}
  end

  protected def authorize(csrftoken, session)
    logger.debug { "STEP 2 - Obtain Authorization Code" } if @debug_payload

    query = URI::Params.build do |form|
      form.add("client_id", @client_id)
      form.add("response_type", "code")
      form.add("scope", "all")
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/json",
      "X-CSRF-Token" => csrftoken,
      "Cookie"       => "session=#{session}",
    }

    payload = {
      "customer_id" => @customer_id,
    }.to_json

    logger.debug { {msg: "Authorize HTTP Data:", headers: headers.to_json, query_params: query.to_s, payload: payload} } if @debug_payload

    response = post("/oauth2/authorize/central/api?#{query}", headers: headers, body: payload)
    raise "failed to obtain authorization code , response code #{response.status_code}, body: #{response.body}" unless response.success?
    body = JSON.parse(response.body).as_h
    raise "no authorization code returned by server" unless body["auth_code"]?
    body["auth_code"].as_s
  end

  protected def accquire_token(auth_code)
    logger.debug { "STEP 3 - Accquire the Access Token" } if @debug_payload

    payload = {
      "client_id"     => @client_id,
      "client_secret" => @client_secret,
      "grant_type"    => "authorization_code",
      "code"          => auth_code,
    }.to_json

    headers = HTTP::Headers{
      "Content-Type" => "application/json",
    }
    logger.debug { {msg: "Accquire Token HTTP Data:", headers: headers.to_json, payload: payload} } if @debug_payload

    response = post(" /oauth2/token", headers: headers, body: payload)
    raise "failed to accquire access token , response code #{response.status_code}, body: #{response.body}" unless response.success?
    Model::AuthToken.from_json(response.body)
  end

  protected def refresh_token
    logger.debug { {msg: "Attempting to refresh Access Token", expiry: auth_token.expiry.to_s, current: Time.utc.to_s, cond: 1.minute.from_now.to_s} } if @debug_payload

    query = URI::Params.build do |form|
      form.add("grant_type", "refresh_token")
      form.add("client_id", @client_id)
      form.add("client_secret", @client_secret)
      form.add("refresh_token", auth_token.refresh_token)
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/json",
    }
    logger.debug { {msg: "Refresh Token HTTP Data:", headers: headers.to_json, query_params: query.to_s} } if @debug_payload

    response = post("/oauth2/token?#{query}", headers: headers)
    raise "failed to refresh access token for client-id #{@client_id}, code #{response.status_code}, body #{response.body}" unless response.success?
    @auth_token = Model::AuthToken.from_json(response.body)
    define_setting(:aruba_token_pair, auth_token)
    auth_token
  end

  protected def keep_token_refreshed : Nil
    return unless auth_token?
    refresh_token if 1.minute.from_now >= auth_token.expiry
  end
end
