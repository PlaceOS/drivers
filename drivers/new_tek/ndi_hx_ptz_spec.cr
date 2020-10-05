DriverSpecs.mock_driver "NewTek::NDI::HxPTZ" do
  # Send the request
  retval = exec(:query_status)

  # Return a status response
  expect_http_request do |request, response|
    if io = request.body
      data = io.gets_to_end

      # The request is param encoded
      if data == "grant_type=client_credentials" && request.headers["Authorization"] == "Basic #{Base64.strict_encode("10000000:c5a6adc6-UUID-46e8-b72d-91395bce9565")}"
        response.status_code = 200
        response.output.puts %({
          "token": "#{token}",
          "access_token": "#{token}",
          "token_type": "bearer",
          "expires_in": 3599
        })
      else
        response.status_code = 401
        response.output.puts ""
      end
    else
      raise "expected request to include token type"
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq("Bearer #{token}")
end
