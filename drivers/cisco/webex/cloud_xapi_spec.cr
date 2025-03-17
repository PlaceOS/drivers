require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::Webex::Cloud" do
  settings({
    cisco_client_id:      "client-id",
    cisco_client_secret:  "client-secret",
    cisco_target_orgid:   "target-org",
    cisco_app_id:         "my-app",
    cisco_personal_token: "my-personal-token",
    debug_payload:        true,
  })

  ret_val = exec(:led_colour?, "device1-id")

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/v1/applications/my-app/token"
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

  ret_val = exec(:led_colour, "device1-id", :green)

  # invoking another endpoint request should use previously obtained access token

  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["deviceId"] == "device1-id" && request["arguments"]["color"] == "green" && headers["Authorization"] == "Bearer generated-access-token"
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

  ret_val = exec(:msg_prompt, "device1-id", "text", [JSON::Any.new("one")], "title", "feedback_id", 32)
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"status": "OK"})
  end

  ret_val.get.try &.as_h["status"].should eq "OK"
end

def color_resp(device_id : String)
  {"deviceId" => device_id, "result" => {"LedControl" => {"Color" => "Green"}}}
end

def color_set_resp
  {"deviceId" => "device1-id", "arguments" => {"Color" => "Green"}}
end

def device_resp_json
  {
    "expires_in":               64799,
    "token_type":               "Bearer",
    "refresh_token":            "MjZmMzcyZWUtMzI2MS00MmE4LTgyZWMtYTVlMWIxYzBjZjhiODJmYzViOTItMGFi_PF84_1eb65fdf-9643-417f-9974-ad72cae0e10f",
    "access_token":             "generated-access-token",
    "refresh_token_expires_in": 7697037,
  }
end
