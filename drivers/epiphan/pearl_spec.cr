require "placeos-driver/spec"

DriverSpecs.mock_driver "Epiphan::Pearl" do
  settings({
    basic_auth: {
      username: "admin",
      password: "admin",
    },
    poll_every: 30,
  })

  # Test list_recorders functionality with actual API response structure
  retval = exec(:list_recorders)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "1",
            "name": "HDMI-A",
            "multisource": false
          },
          {
            "id": "2",
            "name": "HDMI-B",
            "multisource": false
          },
          {
            "id": "3",
            "name": "USB-A",
            "multisource": false
          }
        ]
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  recorders = status["recorders"]?
  recorders.should_not be_nil

  # Test list_channels functionality with actual API response
  retval = exec(:list_channels)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/channels"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "4",
            "name": "CameraTrackingRegie",
            "type": "local"
          },
          {
            "id": "5",
            "name": "CAM1",
            "type": "local"
          },
          {
            "id": "6",
            "name": "CAM2",
            "type": "local"
          }
        ]
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  channels = status["channels"]?
  channels.should_not be_nil

  # Test get_recorder_status functionality
  retval = exec(:get_recorder_status, "1")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders/1/status"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": {
          "state": "stopped",
          "duration": 0,
          "filename": null
        }
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  recorder_status = status["recorder_1_status"]?
  recorder_status.should_not be_nil

  # Test start_recording functionality
  retval = exec(:start_recording, "1")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/recorders/1/control/start"
      response.status_code = 200
      response << %({"status": "ok"})
    else
      response.status_code = 401
    end
  end

  retval.get.should be_true

  # Test stop_recording functionality
  retval = exec(:stop_recording, "1")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/recorders/1/control/stop"
      response.status_code = 200
      response << %({"status": "ok"})
    else
      response.status_code = 401
    end
  end

  retval.get.should be_true

  # Test get_channel_layouts functionality
  retval = exec(:get_channel_layouts, "4")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/channels/4/layouts"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "1",
            "name": "Web+Barco+Cams",
            "active": false
          },
          {
            "id": "2",
            "name": "Barco+Cams",
            "active": false
          },
          {
            "id": "3",
            "name": "Cams",
            "active": true
          }
        ]
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  layouts = status["channel_4_layouts"]?
  layouts.should_not be_nil
end
