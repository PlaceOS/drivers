DriverSpecs.mock_driver "Cisco::Meraki::Dashboard" do
  # Send the request
  retval = exec(:fetch, "/api/v0/organizations")

  # The dashboard should send a HTTP request
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

  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)
end
