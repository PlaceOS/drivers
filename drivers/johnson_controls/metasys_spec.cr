require "placeos-driver/spec"
require "./metasys_models"

DriverSpecs.mock_driver "JohnsonControls::Metasys" do
  username = "user"
  password = "pass"

  settings({
    username: "user",
    password: "pass",
  })

  exec(:get_token)

  expect_http_request do |request, response|
    body = JSON.parse(request.body.not_nil!)
    body["username"].should eq username
    body["password"].should eq password

    response.status_code = 200
    response << %({
      "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6IklFa3FIW...",
      "expires": "#{JohnsonControls::ISO8601.format(Time.utc + 1.day)}"
    })
  end

  exec(:get_equipment_points, "123")

  expect_http_request do |request, response|
    pp request

    response.status_code = 200
    response << %({})
  end
end
