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
end

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
