require "placeos-driver/spec"
require "./sscv2"

DriverSpecs.mock_driver "Sennheiser::SSCv2Driver" do
  settings({
    basic_auth: {
      username: "api",
      password: "test_password",
    },
    running_specs:          true,
    subscription_resources: ["/api/device/site"] of String,
  })

  # Test device identity API
  exec(:device_identity)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    request.method.should eq("GET")
    request.path.should eq("/api/device/identity")

    response.status_code = 200
    response << {
      "product":          "TeamConnect Ceiling Medium",
      "hardwareRevision": "1.0",
      "serial":           "TCC001234",
      "vendor":           "Sennheiser",
    }.to_json
  end

  # Test device site API
  exec(:device_site)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    request.method.should eq("GET")
    request.path.should eq("/api/device/site")

    response.status_code = 200
    response << {
      "deviceName": "Conference Room A",
      "location":   "Building 1, Floor 2",
      "position":   "Main Campus",
    }.to_json
  end

  # Test device state API
  exec(:device_state)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    request.method.should eq("GET")
    request.path.should eq("/api/device/state")

    response.status_code = 200
    response << {
      "state":    "Ok",
      "warnings": [] of String,
    }.to_json
  end

  # Test SSC version API
  exec(:ssc_version)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    request.method.should eq("GET")
    request.path.should eq("/api/ssc/version")

    response.status_code = 200
    response << {
      "version":     "2.0",
      "api_version": "v2",
    }.to_json
  end

  # Test setting device name
  exec(:set_device_name, "New Room Name")
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/device/site")

    body = JSON.parse(request.body.not_nil!)
    body["deviceName"]?.should eq("New Room Name")

    response.status_code = 200
    response << {
      "deviceName": "New Room Name",
      "location":   "Building 1, Floor 2",
      "position":   "Main Campus",
    }.to_json
  end

  # Test setting device location
  exec(:set_device_location, "Building 2, Floor 3")
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/device/site")

    body = JSON.parse(request.body.not_nil!)
    body["location"]?.should eq("Building 2, Floor 3")

    response.status_code = 200
    response << {
      "deviceName": "Conference Room A",
      "location":   "Building 2, Floor 3",
      "position":   "Main Campus",
    }.to_json
  end

  # Test setting device position
  exec(:set_device_position, "Secondary Campus")
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/device/site")

    body = JSON.parse(request.body.not_nil!)
    body["position"]?.should eq("Secondary Campus")

    response.status_code = 200
    response << {
      "deviceName": "Conference Room A",
      "location":   "Building 1, Floor 2",
      "position":   "Secondary Campus",
    }.to_json
  end

  # Test subscription status (should return empty when running specs)
  result = exec(:get_subscription_status)
  status = result.get
  status.should_not be_nil
  if status_hash = status.try(&.as_h)
    status_hash["session_uuid"]?.should eq("")
    status_hash["running"]?.should eq(false)
  end

  # Test that subscription methods don't crash when running specs
  exec(:subscribe_to_resources, ["/api/device/info"])
  exec(:add_subscription_resources, ["/api/device/status"])
  exec(:remove_subscription_resources, ["/api/device/info"])

  # Note: In production (running_specs = false/nil), the driver automatically
  # subscribes to /api/device/status and /api/device/info in addition to
  # any manually configured subscription_resources

  # Test SSE event parsing in models
  event = Sennheiser::SSCv2::SSEEvent.parse_line("event: open")
  event.should_not be_nil
  event.not_nil!.event_type.should eq(Sennheiser::SSCv2::EventType::Open)

  data_line = "data: {\"name\": \"Test Device\"}"
  event = Sennheiser::SSCv2::SSEEvent.parse_line(data_line)
  event.should_not be_nil
  event.not_nil!.event_type.should eq(Sennheiser::SSCv2::EventType::Message)
  event.not_nil!.data["name"]?.should eq("Test Device")

  event = Sennheiser::SSCv2::SSEEvent.parse_line("")
  event.should be_nil

  event = Sennheiser::SSCv2::SSEEvent.parse_line("data: invalid json")
  event.should be_nil

  # Test event type parsing
  Sennheiser::SSCv2::EventType.from_string("open").should eq(Sennheiser::SSCv2::EventType::Open)
  Sennheiser::SSCv2::EventType.from_string("OPEN").should eq(Sennheiser::SSCv2::EventType::Open)
  Sennheiser::SSCv2::EventType.from_string("message").should eq(Sennheiser::SSCv2::EventType::Message)
  Sennheiser::SSCv2::EventType.from_string("").should eq(Sennheiser::SSCv2::EventType::Message)
  Sennheiser::SSCv2::EventType.from_string("close").should eq(Sennheiser::SSCv2::EventType::Close)
  Sennheiser::SSCv2::EventType.from_string("unknown").should eq(Sennheiser::SSCv2::EventType::Message)

  # Test subscription processor initialization
  processor = Sennheiser::SSCv2::SubscriptionProcessor.new("https://device.local", "api", "password")
  processor.base_url.should eq("https://device.local")
  processor.username.should eq("api")
  processor.password.should eq("password")
  processor.running.should eq(false)
  processor.subscribed_resources.should be_empty
  processor.session_uuid.should be_nil

  # Test JSON serialization models
  site = Sennheiser::SSCv2::DeviceSite.new("Test Room", "Building 1", "Campus A")
  json = site.to_json
  parsed = Sennheiser::SSCv2::DeviceSite.from_json(json)
  parsed.deviceName.should eq("Test Room")
  parsed.location.should eq("Building 1")
  parsed.position.should eq("Campus A")

  status_obj = Sennheiser::SSCv2::SubscriptionStatus.new("/api/ssc/state/subscriptions/123", "123")
  json = status_obj.to_json
  parsed_status = Sennheiser::SSCv2::SubscriptionStatus.from_json(json)
  parsed_status.path.should eq("/api/ssc/state/subscriptions/123")
  parsed_status.sessionUUID.should eq("123")

  error = Sennheiser::SSCv2::ErrorResponse.new("/api/device/invalid", 404)
  json = error.to_json
  parsed_error = Sennheiser::SSCv2::ErrorResponse.from_json(json)
  parsed_error.path.should eq("/api/device/invalid")
  parsed_error.error.should eq(404)

  # === Test AudioMuteable Interface ===
  
  # Test mute_audio method (Interface::AudioMuteable)
  exec(:mute_audio, true)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/audio/outputs/global/mute")

    body = JSON.parse(request.body.not_nil!)
    body["enabled"]?.should eq(true)

    response.status_code = 200
    response << {
      "enabled" => true,
    }.to_json
  end

  # Test mute_audio unmute (Interface::AudioMuteable)
  exec(:mute_audio, false)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/audio/outputs/global/mute")

    body = JSON.parse(request.body.not_nil!)
    body["enabled"]?.should eq(false)

    response.status_code = 200
    response << {
      "enabled" => false,
    }.to_json
  end

  # Test mute_audio with index parameter (should still work, index ignored for global mute)
  exec(:mute_audio, true, 1)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/audio/outputs/global/mute")

    body = JSON.parse(request.body.not_nil!)
    body["enabled"]?.should eq(true)

    response.status_code = 200
    response << {
      "enabled" => true,
    }.to_json
  end

  # Test convenience mute method
  exec(:mute, true)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/audio/outputs/global/mute")

    body = JSON.parse(request.body.not_nil!)
    body["enabled"]?.should eq(true)

    response.status_code = 200
    response << {
      "enabled" => true,
    }.to_json
  end

  # Test convenience unmute method
  exec(:unmute)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    headers["Content-Type"]?.should eq("application/json")
    request.method.should eq("PUT")
    request.path.should eq("/api/audio/outputs/global/mute")

    body = JSON.parse(request.body.not_nil!)
    body["enabled"]?.should eq(false)

    response.status_code = 200
    response << {
      "enabled" => false,
    }.to_json
  end

  # Test audio global mute get status
  exec(:audio_global_mute)
  expect_http_request do |request, response|
    headers = request.headers
    headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("api:test_password")}")
    request.method.should eq("GET")
    request.path.should eq("/api/audio/outputs/global/mute")

    response.status_code = 200
    response << {
      "enabled" => false,
    }.to_json
  end
end
