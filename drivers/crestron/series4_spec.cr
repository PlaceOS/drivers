require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::OccupancySensor" do
  full_query = %({
    "Device":{
      "DeviceInfo":{
        "Model":"<model>",
        "Category":"<type>",
        "Manufacturer":"Crestron",
        "DeviceId":"TSID or UUID",
        "SerialNumber":"12345",
        "Name":"Friendly Name",
        "DeviceVersion":"1.2.3",
        "PufVersion":"1.3454.00040.001",
        "BuildDate":"May 13 2016",
        "DeviceKey":"54857",
        "MacAddress":"<mac-address>",
        "RebootReason": "poweron",
        "Version": "2.1.0"
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
    if request.path == "/Device/DeviceInfo/"
      response.status_code = 200
      response << full_query
    else
      response.status_code = 401
      response << "badly formatted"
    end
  end

  sleep 200.milliseconds
  status[:info]["Manufacturer"].should eq "Crestron"
end
