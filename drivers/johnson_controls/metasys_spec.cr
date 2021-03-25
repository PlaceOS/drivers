require "placeos-driver"
require "./metasys.cr"

DriverSpecs.mock_driver "JohnsonControls::Metasys" do
  exec(:get_token)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6IklFa3FIW...",
      "expires": "#{JohnsonControls::Metasys::ISO8601.format(Time.utc + 1.day)}"
    })
  end

  exec(:get_alarms, 1, 2)

  expect_http_request do |request, response|
    pp request.query_params
  end
end
