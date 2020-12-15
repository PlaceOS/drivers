DriverSpecs.mock_driver "Microsoft::FindMe" do
  # Send the request
  retval = exec(:levels)

  # sms should send a HTTP request
  expect_http_request do |request, response|
    response.status_code = 200
    response << %([{"Building":"SYDNEY","Level":"0","Online":13},{"Building":"SYDNEY","Level":"2","Online":14}])
  end

  # What the sms function should return
  retval.get.should eq({
    "SYDNEY" => ["0", "2"],
  })
end
