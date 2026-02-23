require "placeos-driver"
require "placeos-driver/interface/device_info"
require "json"
require "path"
require "uri"
require "./nvx_models"
require "./cres_next_auth"

# Documentation: https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Prerequisites-Assumptions.htm
# inspecting request - response packets from the device webui is also useful

# Parent module for Crestron DM NVX devices.
abstract class Crestron::CresNext < PlaceOS::Driver
  include Crestron::CresNextAuth
  include Interface::DeviceInfo

  def websocket_headers
    authenticate

    headers = HTTP::Headers.new
    transport.cookies.add_request_headers(headers)
    headers["CREST-XSRF-TOKEN"] = @xsrf_token unless @xsrf_token.empty?
    headers["User-Agent"] = "advanced-rest-client"
    headers
  end

  def connected
    schedule.every(10.minutes) { maintain_session }
  end

  def disconnected
    schedule.clear
  end

  def tokenize(path : String)
    path.split('/').reject(&.empty?)
  end

  # ============================================
  # websocket for state changes and get requests
  # ============================================
  protected def query(path : String, **options, &block : (JSON::Any, ::PlaceOS::Driver::Task) -> Nil)
    request_path = Path["/Device"].join(path).to_s
    tokens = tokenize(request_path)
    parts = tokens.map { |part| %("#{part}":) }

    send(request_path, **options) do |data, task|
      raw_json = String.new(data)
      logger.debug { "Crestron sent: #{raw_json}" }

      # check if the response path is included
      unless parts.map(&.in?(raw_json)).includes?(false)
        # Just grab the relevant data as the response is deeply nested
        json = JSON.parse(raw_json)
        tokens.each { |key| json = json[key] }
        block.call json, task
        task.success json
      end
    end
  end

  protected def ws_update(path : String, value, **options)
    request_path = Path["/Device"].join(path).to_s

    # expands into object that we need to post
    components = tokenize(request_path).map { |part| %({"#{part}") }
    payload = %(#{components.join(':')}:#{value.to_json}#{"}" * components.size})

    apply_ws_changes(payload, **options)
  end

  private def apply_ws_changes(payload : String, **options)
    logger.debug { "Sending WebSocket update: #{payload}" }
    send(payload, **options) do |data, task|
      raw_json = String.new(data)
      logger.debug { "Crestron sent: #{raw_json}" }

      if raw_json.includes? %("Results":)
        task.success JSON.parse(raw_json)
      end
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def manual_send(payload : JSON::Any)
    data = payload.to_json
    logger.debug { "Sending: #{data}" }
    send data, wait: false
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }
  end

  # ========================================
  # HTTP for updates and session maintenance
  # ========================================
  def maintain_session : Nil
    device_info
  end

  def device_info : Descriptor
    response = get("/Device/DeviceInfo")
    unless response.success?
      authenticate
      response = get("/Device/DeviceInfo")
      raise "bad credentials, unauthenticated" unless response.success?
    end
    payload = JSON.parse(response.body)
    logger.debug { "device details payload: #{payload.to_pretty_json}" }

    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceInfo.htm
    ip_address = config.ip.presence || URI.parse(config.uri.as(String)).hostname

    model = payload.dig("Device", "DeviceInfo", "Model").as_s
    model_type = payload.dig?("Device", "DeviceInfo", "ModelSubType").try(&.as_s?)
    model_type = " (#{model_type})" if model_type.presence
    category = payload.dig("Device", "DeviceInfo", "Category").as_s

    fw_version = payload.dig("Device", "DeviceInfo", "Version").as_s
    hw_version = payload.dig("Device", "DeviceInfo", "DeviceVersion").as_s
    puf_version = payload.dig("Device", "DeviceInfo", "PufVersion").as_s
    build_date = payload.dig("Device", "DeviceInfo", "BuildDate").as_s
    mac = payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    name = payload.dig?("Device", "DeviceInfo", "Name").try(&.as_s?).presence

    Descriptor.new(
      make: "Crestron",
      model: "#{category} #{model}#{model_type}",
      serial: payload.dig("Device", "DeviceInfo", "SerialNumber").as_s,
      firmware: "#{fw_version}, device #{hw_version}, puf #{puf_version}, built #{build_date}",
      mac_address: mac,
      ip_address: ip_address,
      hostname: name,
    )
  end

  # payload is expected to be a hash or named tuple
  protected def update(path : String, value, **options)
    request_path = Path["/Device"].join(path).to_s

    # expands into object that we need to post
    components = tokenize(request_path).map { |part| %({"#{part}") }
    payload = %(#{components.join(':')}:#{value.to_json}#{"}" * components.size})

    apply_http_changes(request_path, payload, **options)
  end

  private def apply_http_changes(request_path : String, payload : String, **options)
    queue(**options) do |task|
      response = post request_path, body: payload, headers: HTTP::Headers{"CREST-XSRF-TOKEN" => @xsrf_token}
      logger.debug { "updated requested for #{request_path}, response was #{response.body}" }

      # no real need to parse the responses as the changes will be sent down the websocket
      if response.success?
        task.success JSON.parse(response.body)
      else
        task.abort "crestron failed to apply changes to: #{request_path}\n#{response.body}"
      end
    end
  end
end
