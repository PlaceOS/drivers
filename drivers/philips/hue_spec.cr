require "placeos-driver/spec"

DriverSpecs.mock_driver "MessageMedia::SMS" do
  # Connect response (both return a 200 success response)
  success_json = "[{\"success\":{\"username\":\"KrSPjVbcROQj4MIhQ1U2XZ2hgi-jznfhBL8eBZIt\",\"clientkey\":\"26CE9D1876E8570DA1C6A56F2A08F4AA\"}}]"
  error_json = "[{\"error\":{\"type\":101,\"address\":\"\",\"description\":\"link button not pressed\"}}]"

  # Fail a registration request
  retval = exec(:register)
  expect_http_request do |_request, response|
    response.status_code = 200
    response << error_json
  end
  retval.get.should eq("link button not pressed")

  # succeed at registration
  retval = exec(:register)
  expect_http_request do |_request, response|
    response.status_code = 200
    response << success_json
  end
  retval.get.should eq("KrSPjVbcROQj4MIhQ1U2XZ2hgi-jznfhBL8eBZIt")
end
