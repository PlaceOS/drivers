
EngineSpec.mock_driver "PointGrab::CogniPoint" do
  # Send the request
  retval = exec(:get_token)
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzY29wZSI6WyJSRUFEIiwiV1JJVEUiXSwiZXhwIjoxNTc0MjMzNjEyLCJhdXRob3JpdGllcyI6WyJST0xFX1RSVVNURURfQ0xJRU5UIl0sImp0aSI6IjM1ZjkxYjlkLTVmZmMtNDJkYy05YWZkLTJiZTE0YjI1MmE1NCIsImNsaWVudF9pZCI6IjEwMDAwMjEzIn0.Wzrsaey5z3ShAFYKOaWmgfoRZNsk-PclSK9IRtYf4b8"

  # We should request a new token from Floorsense
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
