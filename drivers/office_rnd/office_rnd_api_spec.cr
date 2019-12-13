EngineSpec.mock_driver "OfficeRnd::OfficeRndApi" do
  # Send the request
  retval = exec(:get_token)
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzY29wZSI6WyJSRUFEIiwiV1JJVEUiXSwiZXhwIjoxNTc0MjMzNjEyLCJhdXRob3JpdGllcyI6WyJST0xFX1RSVVNURURfQ0xJRU5UIl0sImp0aSI6IjM1ZjkxYjlkLTVmZmMtNDJkYy05YWZkLTJiZTE0YjI1MmE1NCIsImNsaWVudF9pZCI6IjEwMDAwMjEzIn0.Wzrsaey5z3ShAFYKOaWmgfoRZNsk-PclSK9IRtYf4b8"

  expect_http_request do |request, response|
    case request.path
    when "/oauth/token"
      data = HTTP::Params.parse request.body
      # The request is param encoded
      if data["grant_type"] == "client_credentials" && data["client_secret"] == "c5a6adc6-UUID-46e8-b72d-91395bce9565"
        response.status_code = 200
        response.output.puts %({
          "access_token": "#{token}",
          "token_type": "Bearer",
          "expires_in": 3599,
          "scope": "officernd.api.read officernd.api.write"
        })
      else
        response.status_code = 401
        response.output.puts ""
      end
    when .starts_with?("/bookings")
      case request.method
      when "DELETE"
        # TODO: Delete booking mock response
      when "GET"
        # TODO: Get bookings mock response
      when "POST"
        # TODO: Create bookings mock response
      end
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq("Bearer #{token}")
end
