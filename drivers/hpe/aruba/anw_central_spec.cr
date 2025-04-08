require "placeos-driver/spec"

DriverSpecs.mock_driver "HPE::ANW::Aruba" do
  settings({
    client_id:     "aruba-client",
    client_secret: "aruba-secret",
    customer_id:   "aruba-id",
    username:      "aruba",
    password:      "aruba-pwd",
    debug_payload: true,
  })

  ret_val = exec(:wifi_locations, start_query_time: Time.utc - 5.days, site_id: "24833497", building_id: "building-2", floor_id: "Level2")

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/oauth2/authorize/central/api/login"
      response.status_code = 200
      response.headers["Set-Cookie"] = "session=session-token;csrftoken=csrf-token-1"
    else
      response.status_code = 401
    end
  end

  expect_http_request(2.seconds) do |request, response|
    headers = request.headers
    if request.path == "/oauth2/authorize/central/api"
      if headers["Cookie"] == "session=session-token" && headers["X-CSRF-Token"] == "csrf-token-1"
        response.status_code = 200
        response << {"auth_code" => "auth-code-1"}.to_json
      else
        response.status_code = 409
      end
    else
      response.status_code = 401
    end
  end

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/oauth2/token"
      io = request.body
      if io
        data = io.gets_to_end
        request = JSON.parse(data)
        if request["client_id"] == "aruba-client" && request["client_secret"] == "aruba-secret" && request["grant_type"] == "authorization_code" && request["code"] == "auth-code-1"
          response.status_code = 200
          response << auth_token_json.to_json
        else
          response.status_code = 401
        end
      else
        raise "expected request to include excute command body params #{request.inspect}"
      end
    end
  end

  expect_http_request(2.seconds) do |request, response|
    if request.headers["Authorization"]? == "Bearer generated-access-token"
      response.status_code = 200
      response << wifi_client_locations_resp.to_json
    else
      response.status_code = 401
    end
  end

  ret_val.get.try &.as_h["count"].as_i.should eq 1

  ret_val = exec(:client_location, "macaddr")
  expect_http_request(2.seconds) do |request, response|
    if request.path == "visualrf_api/v1/client_location/macaddr" && request.headers["Authorization"]? == "Bearer generated-access-token"
      response.status_code = 200
      response << client_location_resp.to_json
    else
      response.status_code = 401
    end
  end

  ret_val.get.try &.as_h["device_mac"].as_s.should eq "ac:37:43:a9:ec:10"
end

def wifi_client_locations_resp
  {
    "items": [
      {
        "type":                 "network-monitoring/gateway-monitoring",
        "id":                   "11:22:33:44:55:66-1234567890123",
        "siteId":               "24833497",
        "buildingId":           "bld2bd91-de81-4097-8420-3ca7f87450fd",
        "floorId":              "16a-aad7-4070-8a19-fd6b8e1ff012",
        "macAddress":           "11:22:33:44:55:66",
        "hashedMacAddress":     "43ddc7ed75eb039db1fec4839c0e33d21bfb21e1",
        "associated":           true,
        "associatedBssid":      "11:22:33:44:55:77",
        "cartesianCoordinates": {
          "unit":      "METERS",
          "xPosition": 19,
          "yPosition": 74,
        },
        "geoCoordinates": {
          "latitude":  45.687416,
          "longitude": -73.622016,
        },
        "clientClassification": "Unknown",
        "accuracy":             25.2,
        "numOfReportingAps":    3,
        "connected":            true,
        "createdAt":            "2023-02-14T12:23:00.000Z",
      },
    ],
    "count": 1,
    "total": 1,
    "next":  1,
  }
end

def auth_token_json
  {
    "expires_in":    7200,
    "token_type":    "Bearer",
    "refresh_token": "refresh-token-1",
    "access_token":  "generated-access-token",
  }
end

def client_location_resp
  {
    "location": {
      "x":           185.55978,
      "y":           35.71597,
      "units":       "FEET",
      "error_level": 61,
      "campus_id":   "201610193176__1b99400c-f5bd-4a17-9a1c-87da89941381",
      "building_id": "201610193176__f2267635-d1b5-4e33-be9b-2bf7dbd6f885",
      "floor_id":    "201610193176__39295d71-fac8-4837-8a91-c1798b51a2ad",
      "associated":  true,
      "device_mac":  "ac:37:43:a9:ec:10",
    },
  }
end
