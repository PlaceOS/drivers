require "placeos-driver"
require "jwt"
require "./models"
require "./generated/**"

class HPE::ANW::ArubaWebSocket < PlaceOS::Driver
  # Discovery Information
  descriptive_name "HPE Aruba Location streaming using websockets"
  generic_name :HPEArubaWebSocket

  uri_base "wss://api-ap.central.arubanetworks.com"

  default_settings({
    username:       "",
    wss_key:        "",
    gateway_domain: "wss://api-ap.central.arubanetworks.com",
    debug_payload:  false,
  })

  @username : String = ""
  @wss_key : String = ""
  @debug_payload : Bool = false

  @storage_lock : Mutex = Mutex.new
  @mac_location_mappings : PlaceOS::Driver::RedisStorage? = nil

  # getter location_data : Hash(String, Model::ClientLocation) { {} of String => Model::ClientLocation }

  def mac_location_mappings(&)
    @storage_lock.synchronize {
      yield @mac_location_mappings.not_nil!
    }
  end

  def on_load
    @mac_location_mappings = PlaceOS::Driver::RedisStorage.new(module_id, "mac_location")
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @wss_key = setting(String, :wss_key)
    @debug_payload = setting?(Bool, :debug_payload) || false

    if uri_override = setting?(String, :gateway_domain)
      transport.http_uri_override = URI.parse uri_override
    else
      transport.http_uri_override = nil
    end

    transport.before_request do |request|
      logger.debug { "requesting: #{request.method} #{request.path}?#{request.query}\n#{request.body}" }
    end
  end

  def connected
    ws_get "/streaming/api"
  end

  def websocket_headers
    HTTP::Headers{
      "UserName"      => @username,
      "Authorization" => get_token,
      "Topic"         => "location",
    }
  end

  def client_location(mac_address : String)
    mac_location_mappings(&.[mac_address]?)
  end

  @[Security(Level::Administrator)]
  def ws_get(uri : String, **options)
    request = "GET #{uri}\r\n"
    logger.debug { "requesting: #{request}" }
    send(request, **options)
  end

  def received(data, task)
    metadata = StreamMessage::MsgProto.from_protobuf(IO::Memory.new(data))
    if metadata.subject == "location"
      if data = metadata.data
        location = Location::StreamLocation.from_protobuf(IO::Memory.new(data))
        update_location(location)
      end
    else
      logger.debug { "Received topic '#{metadata.subject}' not supported" }
    end

    task.try &.success
  end

  private def update_location(loc_stream)
    mac_address = Base64.decode(loc_stream.sta_eth_mac.addr.not_nil!).map { |b| "%02X" % b }.join(":")
    units = Model::MeasurementUnit.parse(loc_stream.unit.to_s)
    dev_type = loc_stream.target_type ? loc_stream.target_type.to_s : nil

    location = Model::ClientLocation.new(x: loc_stream.sta_location_x, y: loc_stream.sta_location_y,
      units: units, error_level: loc_stream.error_level, campus_id: loc_stream.campus_id_string,
      building_id: loc_stream.building_id_string, floor_id: loc_stream.floor_id_string,
      associated: loc_stream.associated, target_dev_type: dev_type, device_mac: mac_address)

    # location_data[mac_address] = location
    mac_location_mappings(&.[mac_address] = location.to_json)
  end

  private def get_token
    claims, _ = JWT.decode(token: @wss_key, verify: false, validate: false)
    iat = Time.unix(claims["Created"].as_i64)
    expiry = iat + 7.days

    return @wss_key if expiry > Time.utc

    headers = HTTP::Headers{
      "Authorization" => @wss_key,
    }
    logger.debug { {msg: "Retrieve/Validate WebSocket Key:", headers: headers.to_json} } if @debug_payload

    response = get("/streaming/token/validate", headers: headers)
    raise "failed to retrieve/validate websocket key , response code #{response.status_code}, body: #{response.body}" unless response.success?
    token = JSON.parse(response.body)
    @wss_key = token.as_h["token"].as_s
    define_setting(:wss_key, @wss_key)
    @wss_key
  end
end
