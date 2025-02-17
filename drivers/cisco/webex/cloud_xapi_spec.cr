require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::Webex::Cloud" do
  settings({
    cisco_client_id:     "client-id",
    cisco_client_secret: "client-secret",
    cisco_device_id:     "device1-id",
  })

  ret_val = exec(:authorize)

  expect_http_request do |request, response|
    if request.path == "/v1/device/authorize"
      response.status_code = 200
      response << auth_resp_json.to_json
    else
      response.status_code = 401
    end
  end

  ret_val.get.should eq("https://oauth-helper-r.wbx2.com/verify?userCode=6587b053970a656c29500e6bced0c1c59290a743ad7e34af474a65085860de57")

  ret_val = exec(:led_colour?)

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/v1/device/token"
      response.status_code = 200
      response << device_resp_json.to_json
    else
      response.status_code = 401
    end
  end

  expect_http_request(2.seconds) do |request, response|
    if request.headers["Authorization"]? == "Bearer generated-access-token"
      response.status_code = 200
      response << color_resp(request.query_params["deviceId"]).to_json
    else
      response.status_code = 401
    end
  end

  ret_val.get.should eq(color_resp("device1-id"))

  ret_val = exec(:led_colour, :green)

  # invoking another endpoint request should use previously obtained access token

  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["deviceId"] == "device1-id" && request["arguments"]["Color"] == "Green" && headers["Authorization"] == "Bearer generated-access-token"
        response.status_code = 202
        response << color_set_resp.to_json
      else
        response.status_code = 401
      end
    else
      raise "expected request to include excute command body params #{request.inspect}"
    end
  end

  ret_val.get.should eq(color_set_resp)
end

def color_resp(device_id : String)
  {"deviceId" => device_id, "result" => {"LedControl" => {"Color" => "Green"}}}
end

def color_set_resp
  {"deviceId" => "device1-id", "arguments" => {"Color" => "Green"}}
end

def auth_resp_json
  {
    "device_code":               "5d5cf602-f0dd-49d5-bfd3-915267e4fbe0",
    "expires_in":                300,
    "user_code":                 "729703",
    "verification_uri":          "https://oauth-helper-r.wbx2.com/verify",
    "verification_uri_complete": "https://oauth-helper-r.wbx2.com/verify?userCode=6587b053970a656c29500e6bced0c1c59290a743ad7e34af474a65085860de57",
    "interval":                  1,
  }
end

def device_resp_json
  {
    "scope":                    "meeting:schedules_read",
    "expires_in":               64799,
    "token_type":               "Bearer",
    "refresh_token":            "MjZmMzcyZWUtMzI2MS00MmE4LTgyZWMtYTVlMWIxYzBjZjhiODJmYzViOTItMGFi_PF84_1eb65fdf-9643-417f-9974-ad72cae0e10f",
    "access_token":             "generated-access-token",
    "refresh_token_expires_in": 7697037,
  }
end
