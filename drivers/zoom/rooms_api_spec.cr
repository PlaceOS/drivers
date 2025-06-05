require "placeos-driver/spec"

DriverSpecs.mock_driver "Zoom::RoomsApi" do
  # Mock settings
  settings({
    base_url:      "https://api.zoom.us/v2",
    account_id:    "test_account_id",
    client_id:     "test_client_id",
    client_secret: "test_client_secret",
    room_id:       "qMOLddnySIGGVycz8aX_JQ",
  })

  # Test authentication
  it "should authenticate and get access token" do
    # Mock authentication response
    expect_http_request do |request, response|
      if request.path == "/oauth/token"
        response.status_code = 200
        response.output.puts %({
          "access_token": "test_access_token_123",
          "token_type": "bearer",
          "expires_in": 3600,
          "scope": "room:read:admin room:write:admin"
        })
      else
        raise "unexpected request #{request.path}"
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

    exec(:list_rooms).get
    status[:rooms].should eq([{
      "id"          => "qMOLddnySIGGVycz8aX_JQ",
      "name"        => "Conference Room A",
      "type"        => "ZoomRoom",
      "location_id" => "49D7a0xPQvGQ2DCMZgSe7w",
      "status"      => "Available",
    }])
  end

  # Test room controls - Mute
  it "should mute the microphone" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:mute)
    status[:muted].should eq(true)
  end

  # Test room controls - Unmute
  it "should unmute the microphone" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:unmute)
    status[:muted].should eq(false)
  end

  # Test video mute
  it "should mute video" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:video_mute)
    status[:video_muted].should eq(true)
  end

  # Test join meeting
  it "should join a meeting" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:join_meeting, "123456789", "abc123")
    status[:in_meeting].should eq(true)
  end

  # Test leave meeting
  it "should leave a meeting" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:leave_meeting)
    status[:in_meeting].should eq(false)
  end

  # Test volume control
  it "should set volume level" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:set_volume, 75)
    status[:volume].should eq(75)
  end

  # Test switch camera
  it "should switch camera" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:switch_camera, "camera_123")
    status[:active_camera].should eq("camera_123")
  end

  # Test content sharing
  it "should start content sharing" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:share_content)
    status[:sharing_content].should eq(true)
  end

  # Test get room details
  it "should get room details" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    result = exec(:get_room).get
    result.should eq({
      "id"          => "qMOLddnySIGGVycz8aX_JQ",
      "name"        => "Conference Room A",
      "type"        => "ZoomRoom",
      "location_id" => "49D7a0xPQvGQ2DCMZgSe7w",
      "status"      => "Available",
      "health"      => "healthy",
    })
  end

  # Test list devices
  it "should list devices" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:list_devices).get
    status[:devices].should eq([{
      "id"            => "device_123",
      "room_name"     => "Conference Room A",
      "device_type"   => "ZoomRoomsComputer",
      "app_version"   => "5.8.0",
      "device_system" => "Win 10",
      "status"        => "Online",
    }])
  end

  # Test sensor data
  it "should get sensor data" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    result = exec(:get_sensor_data).get
    result["sensor_data"]["temperature"]["value"].should eq(22.5)
    result["sensor_data"]["people_count"].should eq(3)
  end

  # Test room check-in
  it "should check in to room" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:check_in, "mycalendar@example.com", "event_123", "room@example.com")
    status[:checked_in].should eq(true)
  end

  # Test restart room
  it "should restart zoom room" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:restart_room)
  end

  # Test list locations
  it "should list locations" do
    # Mock authentication
    expect_http_request do |request, response|
      response.status_code = 200
      response.output.puts %({
        "access_token": "test_access_token_123",
        "token_type": "bearer",
        "expires_in": 3600
      })
    end

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

    exec(:list_locations).get
    status[:locations].should eq([{
      "id"                 => "49D7a0xPQvGQ2DCMZgSe7w",
      "name"               => "Building A",
      "type"               => "building",
      "parent_location_id" => "parent_123",
    }])
  end
end
