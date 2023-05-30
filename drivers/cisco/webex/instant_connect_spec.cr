require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::Webex::InstantConnect" do
  # Send the request
  retval = exec(:create_meeting,
    room_id: "1"
  )

  # HTTP request to get host/guest hash
  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request.to_s.includes?(%("aud" => "a4d886b0-979f-4e2c-a958-3e8c14605e51")) && headers["Authorization"].includes?(%(Bearer))
        response.status_code = 200
        response << RAW_HASH_RESPONSE
      else
        response.status_code = 401
      end
    else
      raise "expected request to include aud & sub details #{request.inspect}"
    end
  end

  # HTTP request to get token/spaceId using host JWT
  expect_http_request do |request, response|
    headers = request.headers
    if request.resource.includes?("api/v1/space/?int=jose&data=")
      response.status_code = 200
      response << RAW_HOST_RESPONSE
    else
      response.status_code = 401
    end
  end

  # HTTP request to get token using guest JWT
  expect_http_request do |request, response|
    headers = request.headers
    if request.resource.includes?("api/v1/space/?int=jose&data=")
      response.status_code = 200
      response << RAW_GUEST_RESPONSE
    else
      response.status_code = 401
    end
  end

  retval.get.should eq(JSON.parse(RETVAL))
end

RAW_HOST_RESPONSE = %({
  "userIdentifier": "Host",
  "isLoggedIn": false,
  "isHost": true,
  "organizationId": "16917798-5582-49a7-92d0-4410f6964000",
  "orgName": "PlaceOS",
  "token": "NmFmZGQwODYtZmIzNi00OTlmLWE3N2QtNzUyNzk2MDk4NDU5MjZlNmM2YmQtNjY2_PF84_e2d06a2e-ac4e-464f-968d-a5f8a5ac6303",
  "spaceId": "Y2lzY29zcGFyazovL3VzL1JPT00vODhhZGM1ODAtOThmMi0xMWVjLThiYjQtZjM2MmNkNDBlZDQ1",
  "visitId": "1",
  "integrationType": "jose"
})

RAW_GUEST_RESPONSE = %({
  "userIdentifier": "Guest",
  "isLoggedIn": false,
  "isHost": false,
  "organizationId": "16917798-5582-49a7-92d0-4410f6964000",
  "orgName": "PlaceOS",
  "token": "NmFmZGQwODYtZmIzNi05OTlmLWE3N2QtMzUyNzk2MDk4NDU5MeZlNmM2YmQtNjY2_PF84_e2d06a2e-ac4e-464f-968d-a5f8a5ac6303",
  "spaceId": "Y2lzY29zcGFyazovL3VzL1JPT00vODhhZGM1ODAtOThmMi0xMWVjLThiYjQtZjM2MmNkNDBlZDQ1",
  "visitId": "1",
  "integrationType": "jose"
})

RAW_HASH_RESPONSE = %({
  "host": [{
    "cipher": "eyJwMnMiOiJCWXpoYmV4W",
    "short": "abc1234"
  }],
  "guest": [{
    "cipher": "eyJwMnMiOiJaVVJsejNsb1",
    "short": "def1234"
  }],
  "baseUrl": "https://somedomain.com/chat/"
})

RETVAL = %({
  "space_id":"Y2lzY29zcGFyazovL3VzL1JPT00vODhhZGM1ODAtOThmMi0xMWVjLThiYjQtZjM2MmNkNDBlZDQ1",
  "host_token":"NmFmZGQwODYtZmIzNi00OTlmLWE3N2QtNzUyNzk2MDk4NDU5MjZlNmM2YmQtNjY2_PF84_e2d06a2e-ac4e-464f-968d-a5f8a5ac6303",
  "guest_token":"NmFmZGQwODYtZmIzNi05OTlmLWE3N2QtMzUyNzk2MDk4NDU5MeZlNmM2YmQtNjY2_PF84_e2d06a2e-ac4e-464f-968d-a5f8a5ac6303",
  "host_url": "https://somedomain.com/chat/abc1234",
  "guest_url": "https://somedomain.com/chat/def1234"
})
