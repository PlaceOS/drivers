require "placeos-driver/spec"

DriverSpecs.mock_driver "KontaktIO::KioCloud" do
  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)

  resp = exec(:find, "0x12:34:A6-789B")

  # The API Key should be included on requests
  expect_http_request do |request, response|
    headers = request.headers
    if headers["Api-Key"]? == "Sign in to Kio Cloud > select Users > select Security > copy the Server API Key"
      response.status_code = 200
      response << %({"content": []})
    else
      response.status_code = 401
    end
  end

  resp.get.should eq nil
end
