DriverSpecs.mock_driver "Lenel::OpenAccess" do
  version = exec(:version)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/version")
    res.headers["Content-Type"] = "application/json"
    res.status_code = 200
    res.output << <<-JSON
      {
        "product_name": "OnGuard 7.6",
        "product_version": "7.6.001",
        "version": "1.0"
      }
    JSON
  end
  version = version.get.not_nil!
  version["product_version"].should eq("7.6.001")
end
