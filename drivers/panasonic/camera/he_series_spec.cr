require "placeos-driver/spec"

DriverSpecs.mock_driver "Panasonic::Camera::HESeries" do
  # Send the request
  retval = exec(:zoom?)

  # sms should send a HTTP request
  expect_http_request do |request, response|
    cmd = request.query_params["cmd"]
    if cmd == "#GZ"
      response.status_code = 200
      response.write "gZ0F".to_slice
    else
      raise "expected request: #{cmd}"
    end
  end

  # What the sms function should return
  retval.get.should eq(0xF)
  status[:zoom].should eq 0xF
end
