require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::OccupancySensor" do
  # use a short smoothing window so the sliding-window flip is observable within
  # the spec's real-time sleeps (production defaults are minutes)
  settings({
    username: "admin",
    password: "admin",

    presence_smoothing_window_sec: 1,
    presence_smoothing_threshold:  0.6,
    presence_evaluation_sec:       1,
  })

  full_query = %({
    "Device": {
      "DeviceInfo": {
        "BuildDate": "May 23 2022  (461338)",
        "Category": "Linux Device",
        "DeviceId": "@E-00107fec2d72",
        "DeviceVersion": "3.0000.00002",
        "Devicekey": "No SystemKey Server",
        "MacAddress": "00.10.7f.ec.2d.72",
        "Manufacturer": "Crestron",
        "Model": "CEN-ODT-C-POE",
        "Name": "Room1-Sensor",
        "PufVersion": "3.0000.00002",
        "RebootReason": "poweron",
        "SerialNumber": "2027NEJ00064",
        "Version": "2.1.0"
      },
      "OccupancySensor": {
        "ForceOccupied": "GET Not Supported, Write Only Property",
        "ForceVacant": "GET Not Supported, Write Only Property",
        "IsGraceOccupancyDetected": false,
        "IsLedFlashEnabled": true,
        "IsRoomOccupied": false,
        "IsShortTimeoutEnabled": false,
        "IsSingleSensorDeterminingOccupancy": true,
        "IsSingleSensorDeterminingVacancy": true,
        "Pir": {
          "IsSensor1Enabled": true,
          "OccupiedSensitivity": "Low",
          "VacancySensitivity": "Low"
        },
        "RawStates": {
          "IsRawEnabled": false,
          "RawOccupancy": false,
          "RawPir": false,
          "RawUltrasonic": false
        },
        "TimeoutSeconds": 120,
        "Ultrasonic": {
          "IsSensor1Enabled": true,
          "IsSensor2Enabled": true,
          "OccupiedSensitivity": "Medium",
          "VacancySensitivity": "Medium"
        },
        "Version": "1.0.2"
      }
    }
  })

  puts "==> authenticating"

  # expect authentication
  expect_http_request do |request, response|
    data = request.body.try(&.gets_to_end)
    if data == "login=admin&passwd=admin"
      response.status_code = 200
      response.headers.add("Set-Cookie", [
        "userstr=61646d696e00;Path=/;Secure;HttpOnly;",
        "userid=483d71e5ce65e6a6689a0e95adb3e2c5ff75ca5582c2f13d669e9213c0eeb9771a6923bf7c1aa1cef460ebf266f3231d;Path=/;Secure;HttpOnly;",
        "iv=6023331f67beb11c89bb515f87580a6a;Path=/;Secure;HttpOnly;",
        "tag=3877a0be20e70900c0ffb6b620e70900;Path=/;Secure;HttpOnly;",
        "AuthByPasswd=crypt:36c319e11b69d1853c6d7070d3da33ec9f3194c840cbbb578f9690a4e9baf7da;Path=/;Secure;HttpOnly;",
        "redirectCookie=;expires=Thu, 01 Jan 1970 00:00:00 GMT;Path=/;Secure;HttpOnly;",
      ])
    else
      response.status_code = 401
      response << "bad password"
    end
  end

  puts "==> long poll fail"

  # expect a series of long polls, this pauses it for 1 second
  expect_http_request do |request, response|
    if request.path == "/Device/Longpoll"
      response.status_code = 500
      response << %("error")
    end
  end

  sleep 0.1.seconds

  puts "==> fetching device details"
  # perform a complete poll
  resp = exec(:poll_device_state)
  expect_http_request do |request, response|
    if request.path == "/Device"
      response.status_code = 200
      response << full_query
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end
  resp.get
  # the initial (vacant) reading is observed and latched as the smoothed output
  status[:occupied].should be_false
  status[:raw_occupied].should be_false
  status[:name].should eq "Room1-Sensor"
  status[:mac].should eq "00107fec2d72"

  puts "==> long polling (sensor now reports occupied)"

  # the sensor starts reporting occupancy - long_poll only RECORDS the raw
  # observation, it no longer publishes occupancy directly. Evaluation of the
  # smoothed state happens independently in update_sensor.
  expect_http_request do |request, response|
    if request.path == "/Device/Longpoll"
      response.status_code = 200
      response << %({"Device": {"OccupancySensor": {"IsRoomOccupied": true}}})
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end

  # wait for the long poll to record the raw observation (raw follows the sensor)
  raw_seen_occupied = false
  40.times do
    exec(:update_sensor).get
    if status[:raw_occupied]?.try(&.as_bool)
      raw_seen_occupied = true
      break
    end
    sleep 0.1.seconds
  end
  raw_seen_occupied.should be_true

  # ...but a single fresh observation must NOT immediately flip the smoothed
  # output - "occupied" stays latched until occupancy dominates the 1s window
  status[:occupied].should be_false

  puts "==> waiting for the smoothing window to fill"

  # once occupancy has dominated the window the smoothed output switches on
  became_occupied = false
  40.times do
    exec(:update_sensor).get
    if status[:occupied]?.try(&.as_bool)
      became_occupied = true
      break
    end
    sleep 0.1.seconds
  end
  became_occupied.should be_true

  resp = exec(:get_sensor_details).get.not_nil!
  resp.should eq({
    "status"    => "normal",
    "type"      => "presence",
    "value"     => 1.0,
    "last_seen" => resp["last_seen"].as_i64,
    "mac"       => "00107fec2d72",
    "name"      => "Room1-Sensor",
    "module_id" => "spec_runner",
    "binding"   => "presence",
    "location"  => "sensor",
  })

  puts "==> sensor now reports vacant"

  # the sensor now reports vacant - again long_poll only records the raw reading
  expect_http_request do |request, response|
    if request.path == "/Device/Longpoll"
      response.status_code = 200
      response << %({"Device": {"OccupancySensor": {"IsRoomOccupied": false}}})
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end

  # once vacancy dominates the window the smoothed output switches back off,
  # proving the long poll fed the observation through to update_sensor
  became_vacant = false
  40.times do
    exec(:update_sensor).get
    unless status[:occupied]?.try(&.as_bool)
      became_vacant = true
      break
    end
    sleep 0.1.seconds
  end
  became_vacant.should be_true
end
