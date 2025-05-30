require "placeos-driver/spec"

DriverSpecs.mock_driver "Sennheiser::TeamConnectCM" do
  settings({
    password:      "password",
    device_ip:     "192.168.1.0",
    debug_payload: true,
  })

  ret_val = exec(:device_identity)

  expect_http_request(2.seconds) do |request, response|
    auth = Base64.strict_encode("api:password")
    if request.headers["Authorization"]? == "Basic #{auth}"
      response.status_code = 200
      response << device_identity_resp.to_json
    else
      response.status_code = 401
    end
  end

  ret_val.get.should eq(device_identity_resp)

  ret_val = exec(:set_device_dentification, true)

  expect_http_request(2.seconds) do |request, response|
    auth = Base64.strict_encode("api:password")
    io = request.body
    if io
      data = io.gets_to_end
      body = JSON.parse(data)
      if request.headers["Authorization"]? == "Basic #{auth}"
        response.status_code = 200
        response << body.to_json
      else
        response.status_code = 401
      end
    end
  end

  ret_val.get.should eq({"visual" => true})

  ret_val = exec(:set_device_led_ring, brightness: 5, show_farend_activity: true, mic_on: {color: "Green"}, mic_mute: {color: "Blue"}, mic_custom: {enabled: true, color: "Green"})

  expect_http_request(2.seconds) do |request, response|
    auth = Base64.strict_encode("api:password")
    io = request.body
    if io
      data = io.gets_to_end
      body = JSON.parse(data)
      if request.headers["Authorization"]? == "Basic #{auth}"
        response.status_code = 200
        response << body.to_json
      else
        response.status_code = 401
      end
    end
  end

  ret_val.get.try &.as_h["brightness"].should eq(5)
end

def device_identity_resp
  %(
{
  "product": "TCCM",
  "hardwareRevision": "1",
  "serial": "1023456789",
  "vendor": "Sennheiser electronic GmbH & Co. KG"
}
)
end
