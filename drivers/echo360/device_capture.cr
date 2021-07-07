require "placeos-driver"
require "oq"

# Documentation: https://aca.im/driver_docs/Echo360/EchoSystemCaptureAPI_v301.pdf

class Echo360::DeviceCapture < PlaceOS::Driver
  # Discovery Information
  generic_name :Capture
  descriptive_name "Echo365 Device Capture"
  uri_base "https://echo.server"

  default_settings({
    basic_auth: {
      username: "srvc_acct",
      password: "password!",
    },
  })

  def on_load
    on_update
  end

  def on_update
    schedule.clear
    schedule.every(15.seconds) do
      logger.debug { "-- Polling Capture" }
      system_status
      capture_status
    end
  end

  STATUS_CMDS = {
    system_status:  :system,
    capture_status: :captures,
    next:           :next_capture,
    current:        :current_capture,
    state:          :monitoring,
  }

  {% begin %}
    {% for function, route in STATUS_CMDS %}
      {% path = "/status/#{route.id}" %}
      def {{function.id}}
        response = get({{path}})
        process_status check(response)
      end
    {% end %}
  {% end %}

  @[Security(PlaceOS::Driver::Level::Support)]
  def restart_application
    post("/diagnostics/restart_all").success?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def reboot
    post("/diagnostics/reboot").success?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def captures
    response = get("/diagnostics/recovery/saved-content")
    self[:captures] = check(response)["captures"]["capture"]
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def upload(id : String)
    response = post("/diagnostics/recovery/#{id}/upload")
    raise "upload request failed with #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  # This will auto-start a recording
  def capture(name : String, duration : Int32, profile : String? = nil)
    profile ||= self[:capture_profiles][0].as_s
    response = post("/capture/new_capture", body: URI::Params.build { |form|
      form.add("description", name)
      form.add("duration", duration.to_s)
      form.add("capture_profile_name", profile)
    })
    check(response)["ok"]["#text"].as_s
  end

  def test_capture(name : String, duration : Int32, profile : String? = nil)
    profile ||= self[:capture_profiles][0].as_s
    response = post("/capture/confidence_monitor", body: URI::Params.build { |form|
      form.add("description", name)
      form.add("duration", duration.to_s)
      form.add("capture_profile_name", profile)
    })
    check(response)["ok"]["#text"].as_s
  end

  def extend(duration : Int32)
    response = post("/capture/confidence_monitor", body: URI::Params.build { |form|
      form.add("duration", duration.to_s)
    })
    check(response)["ok"]["#text"].as_s
  end

  def pause
    response = post("/capture/pause")
    check(response)["ok"]["#text"].as_s
  end

  def start
    response = post("/capture/record")
    check(response)["ok"]["#text"].as_s
  end

  def resume
    start
  end

  def record
    start
  end

  def stop
    response = post("/capture/stop")
    check(response)["ok"]["#text"].as_s
  end

  # Converts the response into the appropriate format and indicates success / failure
  protected def check(response)
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    # Convert the XML to JSON for simple parsing
    # https://www.xml.com/pub/a/2006/05/31/converting-between-xml-and-json.html
    input_io = IO::Memory.new response.body
    output_io = IO::Memory.new
    OQ::Converters::XML.deserialize input_io, output_io

    output_io.rewind
    json = JSON.parse(output_io)
    logger.debug { "response was\n#{json.pretty_inspect}" }
    json
  end

  CHECK = {"next", "current"}

  # generic function for processing status and exposing the state
  protected def process_status(data)
    if results = data["status"]?.try(&.as_h)
      results.each do |key, value|
        if key.in?(CHECK) && (value.as_s?.try(&.strip.empty?) || value["schedule"]?.try(&.as_s?.try(&.strip.empty?)))
          # next / current recordings are not present
          self[key] = nil
        elsif key[-1] == 's' && (hash = value.as_h?)
          # This handles `{"api-versions" => {"api-version" => "3.0"}}`
          inner = hash[key[0..-2]]?
          if inner
            self[key] = inner
          else
            self[key] = hash
          end
        elsif str_val = value.as_s?.try(&.strip)
          # cleanup whitespace around string values
          self[key] = str_val
        else
          # otherwise we don't manipulate the value and expose it for use
          self[key] = value
        end
      end
      results
    else
      logger.debug { "namespace 'status' not found, ignoring payload" }
      data
    end
  end
end
