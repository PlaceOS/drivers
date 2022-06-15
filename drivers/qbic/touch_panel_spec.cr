require "placeos-driver/spec"

DriverSpecs.mock_driver "Qbic::TouchPanel" do
  # Send the request
  retval = exec(:get_token)

  # We should request a new token from Floorsense
  expect_http_request do |request, response|
    if io = request.body
      data = io.gets_to_end
      request = JSON.parse(data)

      if request["grant_type"] == "password" && request["username"] == "admin" && request["password"] == "12345678"
        response.status_code = 200
        response.output.puts %({"access_token":"t6pm11le6m6pvae18ar9jqdap4","refresh_token":"gq5c6p1lps3m24nf1th0cmda32","token_type":"Bearer"})
      else
        response.status_code = 400
        response.output.puts %({"detail":"Invalid_client, make sure username and password is correct."})
      end
    else
      raise "expected request to include username and password"
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq("Bearer t6pm11le6m6pvae18ar9jqdap4")

  # Get the list of LEDs on the device
  retval = exec(:leds)

  expect_http_request do |request, response|
    if request.headers["Authorization"]? == "Bearer t6pm11le6m6pvae18ar9jqdap4"
      response.status_code = 200
      response.output.puts %({"results":["side_led", "front_led"]})
    else
      response.status_code = 401
      response.output.puts %({"detail":"Invalid Authorization"})
    end
  end

  retval.get.should eq ["side_led", "front_led"]

  status[:leds].should eq ["side_led", "front_led"]
end
