require "placeos-driver/spec"

DriverSpecs.mock_driver "Keycloak::RestAPI" do
  settings({
    # we grab the HTTP port that the spec is using
    place_domain:  "http://127.0.0.1:#{__get_ports__[1]}",
    place_api_key: "key",
    realm:         "keycloak",
  })

  resp = exec(:get_token, user_id: "user1")
  request_path = ""

  # should send a HTTP to place API to obtain the token
  expect_http_request do |request, response|
    request_path = request.path
    headers = request.headers
    response.status_code = 403 unless headers["X-API-Key"]? == "key"
    response << %({
      "token": "a-token",
      "expires": 123445
    })
  end

  # What the sms function should return
  resp.get.should eq("a-token")
  request_path.should eq "/api/engine/v2/users/user1/resource_token"
end
