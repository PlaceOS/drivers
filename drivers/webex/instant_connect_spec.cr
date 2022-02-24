# require "placeos-driver/spec"

DriverSpecs.mock_driver "Webex::InstantConnect" do
  # Send the request
  retval = exec(:create_meeting,
    meeting_id: "1",
  )

  # InstantConnect should send a HTTP request
  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request.to_s.includes?(%("aud" => "a4d886b0-979f-4e2c-a958-3e8c14605e51")) && headers["Authorization"].includes?(%(Bearer))
        response.status_code = 200
        response << RAW_RESPONSE
      else
        response.status_code = 401
      end
    else
      raise "expected request to include meeting details #{request.inspect}"
    end
  end
  retval.get.should eq(HASHED_RESPONSE)
end

RAW_RESPONSE = %({
  "host": [
      "eyJwMnMiOiJCWXpoYmV4W"
  ],
  "guest": [
      "eyJwMnMiOiJaVVJsejNsb1"
  ]
})

HASHED_RESPONSE = {"host" => "eyJwMnMiOiJCWXpoYmV4W", "guest" => "eyJwMnMiOiJaVVJsejNsb1"}
