require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::OccupancySensor" do
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

  # expect a complete poll
  expect_http_request do |request, response|
    if request.path == "/Device"
      response.status_code = 200
      response << full_query
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end

  sleep 0.5
  status[:occupied].should be_false
  status[:name].should eq "Room1-Sensor"
  status[:mac].should eq "00107fec2d72"

  # followed by a series of long polls
  expect_http_request do |request, response|
    if request.path == "/Device/Longpoll"
      response.status_code = 200
      response << %({"Device": {"OccupancySensor": {"IsRoomOccupied": true}}})
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end

  sleep 0.5
  status[:occupied].should be_true

  resp = exec(:get_sensor_details).get.not_nil!
  resp.should eq({
    "status"    => "normal",
    "type"      => "presence",
    "value"     => 1.0,
    "last_seen" => resp["last_seen"].as_i64,
    "mac"       => "00107fec2d72",
    "name"      => "Room1-Sensor",
    "module_id" => "spec_runner",
    "binding"   => "occupied",
    "location"  => "sensor",
  })
end
