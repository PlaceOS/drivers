require "placeos-driver/spec"
require "./api.cr"

DriverSpecs.mock_driver "Kaiterra::API" do
  exec(:get_devices, "00000000-0031-0101-0000-00007e57c0de")

  expect_http_request do |_, response|
    response.status_code = 200
    response << %({
      "id": "00000000-0031-0101-0000-00007e57c0de",
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
          "param": "rhumid",
          "units": "%",
          "span": 60,
          "points": [
            {
                "ts": "2020-06-17T03:40:00Z",
                "value": 83.58
            }
          ]
        },
        {
          "param": "rco2",
          "units": "ppm",
          "span": 60,
          "points": [
              {
                  "ts": "2022-08-04T02:50:00Z",
                  "value": 432.9
              }
          ]
        }
      ]
    })
  end

  body = Array(Kaiterra::API::Request).from_json(%([
    {
      "method": "GET",
      "relative_url": "/devices/00000000-0001-0101-0000-00007e57c0de/top"
    },
    {
      "method": "GET",
      "relative_url": "/devices/00000000-0031-0001-0000-00007e57c0de/top"
    }
  ]))
  params = {"include_headers" => "true"}
  exec(:batch, body, params)

  expect_http_request do |request, response|
    request.body.not_nil!.gets_to_end.should eq(body.to_json)
    request.query_params["include_headers"].should eq("true")
    response.status_code = 200
    response << %([
      {
        "body": "{\\"data\\":[{\\"param\\":\\"rhumid\\",\\"units\\":\\"%\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":54}]},{\\"param\\":\\"rpm10c\\",\\"units\\":\\"µg/m³\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":120}]},{\\"param\\":\\"rpm25c\\",\\"units\\":\\"µg/m³\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":191}]},{\\"param\\":\\"rtemp\\",\\"units\\":\\"C\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":16}]},{\\"param\\":\\"rtvoc\\",\\"units\\":\\"ppb\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":342}]}]}",
        "code": 200
      },
      {
        "body": "{\\"data\\":[{\\"param\\":\\"rco2\\",\\"units\\":\\"ppm\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":1673}]},{\\"param\\":\\"rhumid\\",\\"source\\":\\"km102\\",\\"units\\":\\"%\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":54.79}]},{\\"param\\":\\"rpm10c\\",\\"source\\":\\"km100\\",\\"units\\":\\"µg/m³\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":125}]},{\\"param\\":\\"rpm25c\\",\\"source\\":\\"km100\\",\\"units\\":\\"µg/m³\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":275}]},{\\"param\\":\\"rtemp\\",\\"source\\":\\"km102\\",\\"units\\":\\"C\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":20.57}]},{\\"param\\":\\"rtvoc\\",\\"source\\":\\"km102\\",\\"units\\":\\"ppb\\",\\"span\\":60,\\"points\\":[{\\"ts\\":\\"2020-06-17T07:05:00Z\\",\\"value\\":435.6}]}]}",
        "code": 200
      }
    ])
  end
end
