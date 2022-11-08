require "placeos-driver"
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

  def websocket_headers
    authenticate

    headers = HTTP::Headers.new
    transport.cookies.add_request_headers(headers)
    headers["CREST-XSRF-TOKEN"] = @xsrf_token unless @xsrf_token.empty?
    headers["User-Agent"] = "advanced-rest-client"

    # This is just to maintain our session at HTTP level
    schedule.clear
    schedule.every(10.minutes) { maintain_session }

    headers
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

      # check if the response path is included
      if parts.map(&.in?(raw_json)).includes?(false)
        # process as an out of band update (not the response)
        received(data, nil)
      else
        logger.debug { "Crestron sent: #{raw_json}" }
        # Just grab the relevant data as the response is deeply nested
        json = JSON.parse(raw_json)
        tokens.each { |key| json = json[key] }
        block.call json, task
        task.success json
      end
    end
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }
  end

  # ========================================
  # HTTP for updates and session maintenance
  # ========================================
  def maintain_session
    response = get("/Device/DeviceInfo")
    return logout unless response.success?

    # we can parse this value as if it came in via the websocket
    received response.body.to_slice, nil
  end

  # payload is expected to be a hash or named tuple
  protected def update(path : String, value, **options)
    queue(**options) do |task|
      request_path = Path["/Device"].join(path).to_s

      # expands into object that we need to post
      components = tokenize(request_path).map { |part| %({"#{part}") }
      payload = %(#{components.join(':')}:#{value.to_json}#{"}" * components.size})

      response = post request_path, body: payload, headers: HTTP::Headers{"CREST-XSRF-TOKEN" => @xsrf_token}
      logger.debug { "updated requested for #{request_path}, response was #{response.body}" }

      # no real need to parse the responses as the changes will be sent down the websocket
      if response.success?
        task.success JSON.parse(response.body)
      else
        task.abort "crestron failed to apply changes to: #{path}\n#{response.body}"
      end
    end
  end
end
