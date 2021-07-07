require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "AWS::SnsSms" do
  # Send the request
  retval = exec(:send_sms,
    phone_numbers: "61418419954",
    message: "hello steve"
  )

  # sms should send a HTTP request
  expect_http_request do |request, response|
    params = request.query_params
    if {params["Action"], params["PhoneNumber"], params["Message"]} == {"Publish", "61418419954", "hello steve"}
      response.status_code = 200
      response << "{\"PublishResponse\":{\"PublishResult\":{\"MessageId\":\"0b486c18-fa23-5f82-a5a0-35200c5f3d96\",\"SequenceNumber\":null},\"ResponseMetadata\":{\"RequestId\":\"6710f384-1a8a-56e3-8b63-aabcecf664f7\"}}}"
    else
      response.status_code = 400
      response << "{}"
    end
  end

  # What the sms function should return
  retval.get.should eq(nil)
end
