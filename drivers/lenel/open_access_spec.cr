private macro respond_with(code, body)
  res.headers["Content-Type"] = "application/json"
  res.status_code = {{code}}
  res.output << {{body}}.to_json
end

DriverSpecs.mock_driver "Lenel::OpenAccess" do
  # Auth on connect
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/authentication")
    respond_with 200, {
      session_token: "abc123",
      token_expiration_time: "#{(Time.utc + 2.weeks).to_rfc3339}"
    }
  end

  # Re-auth on creds update
  settings({username: "foo", password: "bar", directory_id: "baz"})
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/authentication")
    body = JSON.parse req.body.not_nil!
    body["user_name"].should eq("foo")
    body["password"].should eq("bar")
    body["directory_id"].should eq("baz")
    respond_with 200, {
      session_token: "abc123",
      token_expiration_time: "#{(Time.utc + 2.weeks).to_rfc3339}"
    }
  end

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
