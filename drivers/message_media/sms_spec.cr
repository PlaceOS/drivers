require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "MessageMedia::SMS" do
  # Send the request
  retval = exec(:send_sms,
    phone_numbers: "+61418419954",
    message: "hello steve"
  )

  # sms should send a HTTP request
  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["messages"][0]["content"] == "hello steve" && headers["Authorization"]? == "Basic #{Base64.strict_encode("srvc_acct:password!")}"
        response.status_code = 202
      else
        response.status_code = 401
      end
    else
      raise "expected request to include dialing details #{request.inspect}"
    end
  end

  # What the sms function should return
  retval.get.should eq(nil)
end
