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

  def on_update
    schedule_reboot
  end

  def connected
    schedule.clear
    schedule.every(10.minutes) { maintain_session }

    # `schedule.clear` above cancels the reboot task, so re-arm it here
    schedule_reboot
  end

  def disconnected
    schedule.clear
  end

  @reboot_task : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  # Optionally reboot the device on a schedule, configured via the
  # `reboot_cron` (a CRON string) and `reboot_timezone` (IANA name) settings.
  # `reboot` applies a random delay of up to 5 seconds so a fleet of devices
  # sharing a schedule don't all drop off the network at the same instant.
  protected def schedule_reboot : Nil
    @reboot_task.try(&.cancel)
    @reboot_task = nil

    cron = setting?(String, :reboot_cron).presence
    return unless cron

    timezone = setting?(String, :reboot_timezone).presence || "Australia/Sydney"

    begin
      location = Time::Location.load(timezone)
    rescue error
      logger.error(exception: error) { "unknown reboot_timezone #{timezone.inspect}, ignoring reboot schedule" }
      return
    end

    begin
      @reboot_task = schedule.cron(cron, location) { reboot }
      logger.info { "reboot scheduled: #{cron} (#{timezone})" }
    rescue error
      logger.error(exception: error) { "invalid reboot_cron #{cron.inspect}" }
    end
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

      # The device occasionally returns multiple JSON objects in a single
      # frame (e.g. an "Actions"/"Results" ack followed by the state update),
      # separated by a blank line. Parse each line independently.
      raw_json.each_line do |line|
        line = line.strip
        next if line.empty?

        # only consider lines that include the full response path
        next unless parts.all? { |p| line.includes?(p) }

        begin
          json = JSON.parse(line)
          tokens.each { |key| json = json[key] }
          block.call json, task
          task.success json
          break
        rescue error
          logger.warn(exception: error) { "failed to parse Crestron query response line: #{line}" }
        end
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

      # The device may bundle the Actions/Results ack with a state update in
      # the same frame, so we walk each line and only parse the ack line.
      raw_json.each_line do |line|
        line = line.strip
        next if line.empty?
        next unless line.includes? %("Results":)

        begin
          task.success JSON.parse(line)
          break
        rescue error
          logger.warn(exception: error) { "failed to parse Crestron ws update response: #{line}" }
        end
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
    raise "bad credentials, unauthenticated" unless response.success?

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

  @[Security(Level::Administrator)]
  def reboot(now : Bool = false)
    sleep rand(5000).milliseconds unless now
    ws_update "/DeviceOperations/Reboot", true, name: "reboot"
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
