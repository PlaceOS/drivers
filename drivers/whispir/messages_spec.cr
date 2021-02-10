DriverSpecs.mock_driver "Whispir::Messages" do
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
      if request["to"] == "+61418419954" &&
         headers["x-api-key"]? == "12345" &&
         headers["Authorization"]? == "Basic #{Base64.strict_encode("username:password")}"
        response.status_code = 202
        response.headers["Location"] = "https://api.au.whispir.com/messages/id"
      else
        response.status_code = 401
      end
    else
      raise "expected request to include dialing details #{request.inspect}"
    end
  end

  # What the sms function should return
  retval.get.should eq("https://api.au.whispir.com/messages/id")
end
