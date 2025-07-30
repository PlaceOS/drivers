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
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/channels"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "4",
            "name": "CameraTrackingRegie"
          },
          {
            "id": "5",
            "name": "CAM1"
          },
          {
            "id": "6",
            "name": "CAM2"
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
          "active": "0",
          "total": "0"
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
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders/1/control/start" && request.method == "POST"
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
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders/1/control/stop" && request.method == "POST"
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
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/channels/4/layouts"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "1",
            "name": "Web+Barco+Cams"
          },
          {
            "id": "2",
            "name": "Barco+Cams"
          },
          {
            "id": "3",
            "name": "Cams"
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

  # Test pause_recording functionality
  retval = exec(:pause_recording, "1")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders/1/control/pause" && request.method == "POST"
      response.status_code = 200
      response << %({"status": "ok"})
    else
      response.status_code = 401
    end
  end

  retval.get.should be_true

  # Test resume_recording functionality
  retval = exec(:resume_recording, "1")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/recorders/1/control/resume" && request.method == "POST"
      response.status_code = 200
      response << %({"status": "ok"})
    else
      response.status_code = 401
    end
  end

  retval.get.should be_true

  # Test list_publishers functionality
  retval = exec(:list_publishers, "4")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/channels/4/publishers"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": [
          {
            "id": "1",
            "type": "rtmp",
            "name": "RTMP Stream"
          },
          {
            "id": "2",
            "type": "hls",
            "name": "HLS Stream"
          }
        ]
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  publishers = status["channel_4_publishers"]?
  publishers.should_not be_nil

  # Test set_channel_layout functionality
  retval = exec(:set_channel_layout, "4", "3")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" &&
       request.path == "/api/v2.0/channels/4/set_layout" &&
       request.method == "PUT"
      response.status_code = 200
      response << %({"status": "ok"})
    else
      response.status_code = 401
    end
  end

  retval.get.should be_true

  # Test get_system_status functionality
  retval = exec(:get_system_status)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Basic #{Base64.strict_encode("admin:admin")}" && request.path == "/api/v2.0/system/status"
      response.status_code = 200
      response << %({
        "status": "ok",
        "result": {
          "date": "2025-02-14T08:41:09-05:00",
          "uptime": 5490,
          "cpuload": 25,
          "cpuload_high": false,
          "cputemp": 57,
          "cputemp_threshold": 70
        }
      })
    else
      response.status_code = 401
    end
  end

  retval.get
  system_status = status[:system_status]?
  system_status.should_not be_nil
end
