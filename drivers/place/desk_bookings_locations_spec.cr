DriverSpecs.mock_driver "Place::DeskBookingsLocations" do
  settings({
    zone_filter: ["zone-12345"],

    # PlaceOS API creds, so we can query the zone metadata
    username:     "",
    password:     "",
    client_id:    "",
    redirect_uri: "",

    # time in seconds
    poll_rate:      60,
    booking_type:   "desk",
    running_a_spec: true,
  })

  resp = exec(:query_desk_bookings)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "spec-test"
      response.status_code = 200
      response << %([{
        "id": 1234,
        "user_id": "user-12345",
        "user_email": "steve@place.tech",
        "user_name": "Steve T",
        "asset_id": "desk-2-12",
        "zones": ["zone-build1", "zone-level2"],
        "booking_type": "Steve T",
        "booking_start": 123456,
        "booking_end": 12345678,
        "timezone": "Australia/Sydney",
        "checked_in": true,
        "rejected": false,
        "approved": false
      },{
        "id": 5678,
        "user_id": "user-67890",
        "user_email": "bob@place.tech",
        "user_name": "Bob T",
        "asset_id": "desk-2-13",
        "zones": ["zone-build1", "zone-level2"],
        "booking_type": "Bob T",
        "booking_start": 123456,
        "booking_end": 12345678,
        "timezone": "NewZealand/Queenstown",
        "checked_in": false,
        "rejected": true,
        "approved": false
      }])
    else
      response.status_code = 401
    end
  end

  resp.get.should eq(JSON.parse(%({
    "steve@place.tech": [{
      "id": 1234,
      "user_id": "user-12345",
      "user_email": "steve@place.tech",
      "user_name": "Steve T",
      "asset_id": "desk-2-12",
      "zones": ["zone-build1", "zone-level2"],
      "booking_type": "Steve T",
      "booking_start": 123456,
      "booking_end": 12345678,
      "timezone": "Australia/Sydney",
      "checked_in": true,
      "rejected": false,
      "approved": false
    }]
  })))

  resp = exec(:device_locations, "zone-level2")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "spec-test"
      response.status_code = 200
      response << %({
        "tags": ["building", "main"]
      })
    else
      response.status_code = 401
    end
  end

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "spec-test"
      response.status_code = 200
      response << %({
        "tags": ["level"]
      })
    else
      response.status_code = 401
    end
  end

  location_expected = JSON.parse({ {
    location:      :desk_booking,
    at_location:   true,
    map_id:        "desk-2-12",
    level:         "zone-level2",
    building:      "zone-build1",
    mac:           "user-12345",
    booking_start: 123456,
    booking_end:   12345678,
  } }.to_json)

  resp.get.should eq(location_expected)

  # Won't need to lookup the zone details on second request
  exec(:device_locations, "zone-level2").get.should eq(location_expected)

  exec(:macs_assigned_to, "steve@place.tech").get.should eq(["user-12345"])
end
