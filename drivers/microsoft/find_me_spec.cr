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

  # Send the request
  retval = exec(:user_details, "mbenz")
  details_response = %([{"Alias":"mbenz","LastUpdate":"2020-12-15T13:22:00.8675244Z","CurrentUntil":"0001-01-01T00:00:00","Confidence":0,"Coordinates":null,"GPS":null,"LocationIdentifier":null,"Status":"NoData","LocatedUsing":null,"Type":null,"Comments":null,"ExtendedUserData":null,"WiFiScale":0.0,"userTypes":null}])
  expect_http_request do |request, response|
    response.status_code = 200
    response << details_response
  end
  retval.get.should eq([] of JSON::Any)
end
