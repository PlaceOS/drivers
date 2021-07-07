require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::DNASpaces" do
  # The dashboard should request the streaming API
  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-API-KEY"]? == "X-API-KEY"
      response.headers["Transfer-Encoding"] = "chunked"
      response.status_code = 200
      response << %({"recordUid":"event-85b84f15","recordTimestamp":1605502585236,"spacesTenantId":"","spacesTenantName":"","partnerTenantId":"","eventType":"KEEP_ALIVE"})
    else
      response.status_code = 401
    end
  end

  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)
end
