require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::CalendarDelegated" do
  resp = exec(:list_groups)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-API-Key"]? == "key-here"
      response.status_code = 200
      response << %([{
        "id": "1234",
        "name": "Some Group"
      }])
    else
      response.status_code = 401
    end
  end

  resp.get.should eq(JSON.parse(%([{
    "id": "1234",
    "name": "Some Group"
  }])))
end
