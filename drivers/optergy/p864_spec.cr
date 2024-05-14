require "placeos-driver/spec"

DriverSpecs.mock_driver "Optergy::P864" do
  # authenticate
  retval = exec(:version)

  expect_http_request do |request, response|
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["username"] == "admin" && request["password"] == "password"
        response.status_code = 200
        {
          token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjozLCJpYXQiOjI1ODgwNCwiZXhwIjoyODc2MDQsImlzcyI6Ik9wdGVyZ3kiLCJzdWIiOiIyIn0.NqQ4z7RL6rOTYwxc4-VYvxj_11-6YMcS4UeUzFZ3gWc",
        }.to_json(response)
      else
        response.status_code = 401
      end
    else
      raise "expected request to include authentication details #{request.inspect}"
    end
  end

  expect_http_request do |request, response|
    if request.headers["Authorization"]? == "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjozLCJpYXQiOjI1ODgwNCwiZXhwIjoyODc2MDQsImlzcyI6Ik9wdGVyZ3kiLCJzdWIiOiIyIn0.NqQ4z7RL6rOTYwxc4-VYvxj_11-6YMcS4UeUzFZ3gWc"
      response.status_code = 200
      {
        version: "1.1.7",
      }.to_json(response)
    else
      response.status_code = 401
    end
  end

  retval.get.should eq("1.1.7")

  # =================
  # Analog Values
  # =================

  retval = exec(:analog_values)
  expect_http_request do |request, response|
    if request.path == "/api/av/"
      response.status_code = 200
      response << %([{
        "presentValue": "26.0",
        "instance": 1,
        "eventState": "normal",
        "outOfService": false,
        "description": "Light 1",
        "objectName": "Analog Value 1",
        "priorityArray": [
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          "26.0",
          null,
          null
        ],
        "units": 95,
        "tags": [
          ""
        ],
        "objectType": 2,
        "relinquishDefault": "0.0"
      }])
    else
      response.status_code = 500
      response << "GOT PATH: #{request.path}"
    end
  end

  retval.get.should eq([{
    "objectName"   => "Analog Value 1",
    "description"  => "Light 1",
    "presentValue" => "26.0",
    "instance"     => 1,
    "outOfService" => false,
    "units"        => 95,
  }])

  # =================
  # Analog Value
  # =================

  retval = exec(:analog_value, 1)
  expect_http_request do |request, response|
    if request.path == "/api/av/1"
      response.status_code = 200
      response << %({
        "presentValue": "26.0",
        "instance": 1,
        "eventState": "normal",
        "outOfService": false,
        "description": "Light 1",
        "objectName": "Analog Value 1",
        "priorityArray": [
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          "26.0",
          null,
          null
        ],
        "units": 95,
        "tags": [
          ""
        ],
        "objectType": 2,
        "relinquishDefault": "0.0"
      })
    else
      response.status_code = 500
      response << "GOT PATH: #{request.path}"
    end
  end

  retval.get.should eq({
    "objectName"   => "Analog Value 1",
    "description"  => "Light 1",
    "presentValue" => "26.0",
    "instance"     => 1,
    "outOfService" => false,
    "units"        => 95,
  })
end
