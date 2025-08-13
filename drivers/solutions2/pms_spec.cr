require "placeos-driver/spec"

DriverSpecs.mock_driver "PMS" do
  settings({
    username:      "placeos_demo",
    password:      "test-pwd",
    debug_payload: true,
  })

  ret_val = exec(:list_departments)

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/api/Token"
      response.status_code = 200
      response << generate_token.to_json
    else
      response.status_code = 401
    end
  end

  expect_http_request(2.seconds) do |request, response|
    if request.path == "/api/departments"
      response.status_code = 200
      response << departments_data.to_json
    else
      response.status_code = 404
    end
  end

  ret_val.get.try &.as_a.size.should eq 3

  ret_val = exec(:list_vehicles)
  expect_http_request(2.seconds) do |request, response|
    if request.method == "GET" && request.path == "/api/vehicles"
      response.status_code = 200
      response << vehicles_data.to_json
    else
      response.status_code = 404
    end
  end

  ret_val.get.try &.as_a.size.should eq 2
end

def generate_token
  {
    "Data": {
      "token":  "iYambvQ7MSBqZ7_u63VjzqXlG6sq-_xQIUxYcQ9vmjXFaTuTxqrs23SjC7803VRF69iThuXH9rTnOGPawMJhBXf4YIU7pslcp85zZJvJbinM3t-7zsSjNFIBh80B8iBLinhCah8hzd2gCs8Cvd32Lb-fV2L4Rr9Lo_XQQQiS7bx-ebcJL70-sXJrCLZtMUoZ-wFM-XftIpbcIN2M0t8u7tKzywhFDtADY1ILpqcqs7O7XhoHBQXJ560-BoZc-rQajBrWb1TqbUGVNYlF-qs3yI7skkYem8TVATrnH4xt9neo92v4KV7IwlPJ_2pN4R1leSW5RE-oSeURliULdOpD2YsQTNMrm0_Vm6jGvZHGRfirnrfLKVe9aFnXYGCgP8MHw7cFIcVGIaOh7DqOZpmPuZH4A5exJs3hgLIqwA6cIBTyk2dYPUMG9daLfdljAMJy3UzuE3hKjKIjIl7Ze_rQAGJneuKFe7trF0TqCfBOFw51RGMw1JIf7OnHK5nvA4OQmrQgQD_SbjCYRFvs6bbJG0QI_P4c03lHTgFu5L2FgN4_jB7hj1fR7kAFAAe-gY_5",
      "userid": "placeos_demo",
      "expiry": 86399,
    },
    "JsonRequestBehavior": 0,
  }
end

def departments_data
  [
    {
      "Name":         "CMO",
      "ParkingSlots": "10",
      "Status":       "🟢 Enabled",
      "Id":           "af22ac15-b85c-f011-bec2-6045bd69cb6a",
    },
    {
      "Name":         "CMO",
      "ParkingSlots": "12",
      "Status":       "🟢 Enabled",
      "Id":           "af5d4b39-b85c-f011-bec2-6045bd69d9b0",
    },
    {
      "Name":         "PMO1111111",
      "ParkingSlots": "4",
      "Status":       "🟢 Enabled",
      "Id":           "6d407fbb-b75c-f011-bec2-6045bd1585f5",
    },
  ]
end

def vehicles_data
  [
    {
      "PlateNumber":   "0000212",
      "Platesource":   "Dubai",
      "PlateCategory": "Private",
      "PlateCode":     "K",
      "VehicleStatus": "For Approval",
      "Id":            "4fd82430-ea6d-f011-b4cc-6045bd69cb6a",
    },
    {
      "PlateNumber":   "0022545",
      "Platesource":   "Dubai",
      "PlateCategory": "Private",
      "PlateCode":     "K",
      "VehicleStatus": "For Approval",
      "Id":            "8b4afab2-ea6d-f011-b4cc-0022480dcd74",
    },
  ]
end
