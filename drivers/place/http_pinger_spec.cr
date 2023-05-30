require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::HTTPPinger" do
  expect_http_request do |request, response|
    response.status_code = 200
  end

  sleep 1

  status[:last_response_code]?.should eq 200
  status[:connected]?.should eq true

  retval = exec(:check_status)
  expect_http_request do |request, response|
    response.status_code = 400
  end
  retval.get

  status[:last_response_code]?.should eq 400
  status[:response_mismatch_count]?.should eq 1
  status[:connected]?.should eq false
end
