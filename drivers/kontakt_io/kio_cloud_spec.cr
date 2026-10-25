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

  resp = exec(:colocations, "00fab6:02:4B:A3", 1645858383, 1646204290)

  # The API Key should be included on requests
  expect_http_request do |request, response|
    if request.query_params["trackingId"]? == "00:FA:B6:02:4B:A3"
      response.status_code = 200
      response << EXAMPLE_RESPONSE
    else
      response.status_code = 500
    end
  end

  resp.get.should eq JSON.parse(EXAMPLE_COLOCATION)

  # ===================
  # occupancy polling
  # ===================
  settings({
    kio_api_key: "key",
    poll_every:  1,
  })

  # first poll requests the rooms, telemetry and occupancy
  expect_http_request(3.seconds) do |request, response|
    request.path.should eq "/v2/locations/rooms"
    response.status_code = 200
    response << EXAMPLE_ROOMS
  end

  expect_http_request do |request, response|
    request.path.should eq "/v3/telemetry"
    request.query_params["trackingId"].should eq "00:fa:b6:0b:b1:d0"
    response.status_code = 200
    response << EXAMPLE_TELEMETRY
  end

  expect_http_request do |request, response|
    request.path.should eq "/v3/occupancy/rooms"
    response.status_code = 200
    response << %({"content": []})
  end

  sleep 200.milliseconds
  status["room-15"]["occupancy"].should eq 1
  status["rate_limited_until"]?.should eq nil

  # second poll uses the cached rooms and the API rate limits us
  expect_http_request(3.seconds) do |request, response|
    request.path.should eq "/v3/telemetry"
    response.status_code = 429
    response.headers["Retry-After"] = "120"
  end

  # rate limited requests are not retried and polling is paused
  sleep 200.milliseconds
  resume_at = status["rate_limited_until"].as_i64
  resume_at.should be_close(120.seconds.from_now.to_unix, 2)

  # no further requests are made during the backoff period
  expect_raises(Exception, "timeout waiting for expected HTTP request") do
    expect_http_request(2.seconds) { |_request, response| response.status_code = 200 }
  end
end

EXAMPLE_ROOMS = %({
  "content": [{
    "id": 15,
    "name": "Meeting Room 1",
    "roomType": "MEETING_ROOM",
    "floor": {"id": 3, "name": "Level 1"},
    "roomSensors": [{"trackingId": "00:fa:b6:0b:b1:d0"}]
  }],
  "page": {"size": 500, "number": 0, "totalElements": 1, "totalPages": 1}
})

EXAMPLE_TELEMETRY = %({
  "content": [{
    "trackingId": "00:fa:b6:0b:b1:d0",
    "secondsSincePirMotion": 20,
    "timestamp": "2026-10-25T22:54:10.320Z"
  }],
  "page": {"size": 500, "number": 0, "totalElements": 1, "totalPages": 1}
})

EXAMPLE_COLOCATION = %([
    {
          "trackingId": "00:fa:b6:03:c0:1b",
          "startTime": "2022-02-25T04:02:43Z",
          "endTime": "2022-03-02T04:02:43Z",
          "contacts": [
              {
                  "trackingId": "00:fa:b6:02:4b:a3",
                  "durationSec": 7662
              }
          ]
      },
      {
          "trackingId": "00:fa:b6:03:c0:1e",
          "startTime": "2022-02-25T04:02:43Z",
          "endTime": "2022-03-02T04:02:43Z",
          "contacts": [
              {
                  "trackingId": "00:fa:b6:02:4b:a3",
                  "durationSec": 2386
              }
          ]
      }
  ])

EXAMPLE_RESPONSE = %({"content": #{EXAMPLE_COLOCATION}})
