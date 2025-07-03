require "placeos-driver/spec"

DriverSpecs.mock_driver "Zoom::RoomsApi" do
  # Mock settings
  settings({
    account_id:    "test_account_id",
    client_id:     "test_client_id",
    client_secret: "test_client_secret",
    room_id:       "qMOLddnySIGGVycz8aX_JQ",
  })

  retval = exec(:list_rooms)
  # Mock authentication response
  expect_http_request do |request, response|
    if request.path == "/oauth/token"
      response.status_code = 200
      response.output.puts %({
          "access_token": "test_access_token_123",
          "token_type": "bearer",
          "expires_in": 3600,
          "scope": "room:read:admin room:write:admin",
          "api_url": "https://api.zoom.us"
        })
    else
      response.status_code = 500
    end
  end

  # Mock list rooms request with authentication
  expect_http_request do |request, response|
    if request.path == "/v2/rooms"
      response.status_code = 200
      response.output.puts %({
          "page_size": 30,
          "rooms": [
            {
              "id": "qMOLddnySIGGVycz8aX_JQ",
              "name": "Conference Room A",
              "type": "ZoomRoom",
              "location_id": "49D7a0xPQvGQ2DCMZgSe7w",
              "status": "Available"
            }
          ]
        })
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get.try &.as_h["rooms"].should eq([{
    "id"          => "qMOLddnySIGGVycz8aX_JQ",
    "name"        => "Conference Room A",
    "type"        => "ZoomRoom",
    "location_id" => "49D7a0xPQvGQ2DCMZgSe7w",
    "status"      => "Available",
  }])

  retval = exec(:mute)

  # Mock mute request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.mute")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get

  retval = exec(:unmute)
  # Mock unmute request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.unmute")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get
  status[:muted].should eq(false)

  retval = exec(:video_mute)
  # Mock video mute request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.video_mute")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end
  retval.get
  status[:video_muted].should eq(true)

  retval = exec(:join_meeting, "123456789", "abc123")
  # Mock join meeting request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.meeting_join")
      body["params"]["meeting_number"].should eq("123456789")
      body["params"]["password"].should eq("abc123")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end
  retval.get
  status[:in_meeting].should eq(true)

  retval = exec(:leave_meeting)
  # Mock leave meeting request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.meeting_leave")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get
  status[:in_meeting].should eq(false)

  retval = exec(:set_volume, 75)
  # Mock volume control request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.volume_level")
      body["params"]["level"].should eq(75)
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end
  retval.get
  status[:volume].should eq(75)

  retval = exec(:switch_camera, "camera_123")
  # Mock switch camera request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.switch_camera")
      body["params"]["camera_id"].should eq("camera_123")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get
  status[:active_camera].should eq("camera_123")

  retval = exec(:share_content)
  # Mock content sharing request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.share_content_start")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end
  retval.get
  status[:sharing_content].should eq(true)

  retval = exec(:get_room)
  # Mock get room request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ"
      response.status_code = 200
      response.output.puts %({
          "id": "qMOLddnySIGGVycz8aX_JQ",
          "name": "Conference Room A",
          "type": "ZoomRoom",
          "location_id": "49D7a0xPQvGQ2DCMZgSe7w",
          "status": "Available",
          "health": "healthy"
        })
    else
      raise "unexpected request #{request.path}"
    end
  end

  result = retval.get
  result.should eq({
    "id"          => "qMOLddnySIGGVycz8aX_JQ",
    "name"        => "Conference Room A",
    "type"        => "ZoomRoom",
    "location_id" => "49D7a0xPQvGQ2DCMZgSe7w",
    "status"      => "Available",
    "health"      => "healthy",
  })

  retval = exec(:list_devices)
  # Mock list devices request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/devices"
      response.status_code = 200
      response.output.puts %({
          "devices": [
            {
              "id": "device_123",
              "room_name": "Conference Room A",
              "device_type": "ZoomRoomsComputer",
              "app_version": "5.8.0",
              "device_system": "Win 10",
              "status": "Online"
            }
          ]
        })
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get

  status[:devices].should eq([{
    "id"            => "device_123",
    "room_name"     => "Conference Room A",
    "device_type"   => "ZoomRoomsComputer",
    "app_version"   => "5.8.0",
    "device_system" => "Win 10",
    "status"        => "Online",
  }])

  retval = exec(:get_sensor_data)
  # Mock sensor data request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/sensor_data"
      response.status_code = 200
      response.output.puts %({
          "sensor_data": {
            "temperature": {
              "value": 22.5,
              "unit": "celsius"
            },
            "humidity": {
              "value": 45,
              "unit": "percentage"
            },
            "people_count": 3
          }
        })
    else
      raise "unexpected request #{request.path}"
    end
  end

  result = retval.get.not_nil!.as_h
  result["sensor_data"]["temperature"]["value"].should eq(22.5)
  result["sensor_data"]["people_count"].should eq(3)

  retval = exec(:check_in, "mycalendar@example.com", "event_123", "room@example.com")
  # Mock check-in request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.check_in")
      body["params"]["calendar_id"].should eq("mycalendar@example.com")
      body["params"]["event_id"].should eq("event_123")
      body["params"]["resource_email"].should eq("room@example.com")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get
  status[:checked_in].should eq(true)

  retval = exec(:restart_room)
  # Mock restart request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/qMOLddnySIGGVycz8aX_JQ/events"
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("zoomroom.restart")
      response.status_code = 202
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get

  retval = exec(:list_locations)
  # Mock list locations request
  expect_http_request do |request, response|
    if request.path == "/v2/rooms/locations"
      response.status_code = 200
      response.output.puts %({
          "locations": [
            {
              "id": "49D7a0xPQvGQ2DCMZgSe7w",
              "name": "Building A",
              "type": "building",
              "parent_location_id": "parent_123"
            }
          ]
        })
    else
      raise "unexpected request #{request.path}"
    end
  end

  retval.get
  status[:locations].should eq([{
    "id"                 => "49D7a0xPQvGQ2DCMZgSe7w",
    "name"               => "Building A",
    "type"               => "building",
    "parent_location_id" => "parent_123",
  }])
end
