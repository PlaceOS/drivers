require "placeos-driver/spec"

private macro respond_with(code, body)
  res.headers["Content-Type"] = "application/json"
  res.status_code = {{code}}
  res.output << {{body}}
end

DriverSpecs.mock_driver "Juniper::Mist" do
  sites = exec(:sites)
  sites_data = %([
      {
          "timezone": "America/Los_Angeles",
          "country_code": "US",
          "latlng": {
              "lat": 37.363863,
              "lng": -121.901098
          },
          "id": "532e5b63-b008-4914-878c-c8f1cfac28bb",
          "name": "Primary Site",
          "org_id": "4f3aaa38-8c1b-4fb2-831d-0fff125b3ce7",
          "created_time": 1635222250,
          "modified_time": 1635222250,
          "rftemplate_id": null,
          "aptemplate_id": null,
          "secpolicy_id": null,
          "alarmtemplate_id": null,
          "networktemplate_id": null,
          "gatewaytemplate_id": null,
          "tzoffset": 960
      }
  ])
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/orgs/org_id/sites")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with 200, sites_data
  end
  sites = sites.get.not_nil!
  sites.should eq(JSON.parse(sites_data))
end
