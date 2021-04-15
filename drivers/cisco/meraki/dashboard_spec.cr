require "./scanning_api"

DriverSpecs.mock_driver "Cisco::Meraki::Dashboard" do
  # Send the request
  retval = exec(:fetch, "/api/v0/organizations")

  # The dashboard should send a HTTP request with the API key
  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-Cisco-Meraki-API-Key"]? == "configure for the dashboard API"
      response.status_code = 202
      response << %([{"id":"org id","name":"place tech"}])
    else
      response.status_code = 401
    end
  end

  # Should return the payload
  retval.get.should eq %([{"id":"org id","name":"place tech"}])
end
