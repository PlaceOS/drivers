require "placeos-driver/spec"

DriverSpecs.mock_driver "Kaiterra::API" do
  device_ids = [
    "00000000-0031-0101-0000-00007e57c0de",
    "0000000000010101000000007e57c0de"
  ]

  settings({
    api_key: "apikey",
    device_ids: device_ids
  })

  exec(:get_devices, device_ids[0])

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": [
        {
          "param": "rpm25c",
          "units": "µg/m³",
          "source": "km100",
          "span": 60,
          "points": [
            {
                "ts": "2020-06-17T03:40:00Z",
                "value": 120
            }
          ]
        },
        {
          "param": "rtemp",
          "units": "%",
          "span": 60,
          "points": [
            {
                "ts": "2020-06-17T03:40:00Z",
                "value": 62
            }
          ]
        }
      ]
    })
  end
end
