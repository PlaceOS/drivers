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

  # Version lookup
  version = exec(:version)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/version")
    req.headers["Session-Token"].should eq("abc123")
    respond_with 200, {
      product_name: "OnGuard 7.6",
      product_version: "7.6.001",
      version: "1.0"
    }
  end
  version = version.get.not_nil!
  version["product_version"].should eq("7.6.001")


  # Error handling
  failing_request = exec(:version)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/version")
    respond_with 401, {
      error: {
        code: "openaccess.general.invalidapplicationid",
        message: "You are not licensed for OpenAccess."
      }
    }
  end
  # FIXME: the test runner does not appear to be able to resolve this?
  #expect_raises(Lenel::OpenAccess::Error) do
  expect_raises(Exception) do
    failing_request.get
  end


  # Visitor creation, search and destroy

  example_visitor = {
    email: "foo@bar.com",
    firstname: "Kel",
    lastname: "Varnsen",
    organization: "Vandelay Industries",
    title: "Sales",
  }

  created_visitor = exec(:create_visitor, **example_visitor)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/count")
    req.query_params["type_name"]?.should eq("Lnl_Visitor")
    req.query_params["filter"]?.should eq(%(email="foo@bar.com"))
    respond_with 200, { total_items: 0 }
  end
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Visitor")
    body["property_value_map"]?.try do |prop|
      prop["email"].should eq("foo@bar.com")
      prop["firstname"].should eq("Kel")
      prop["lastname"].should eq("Varnsen")
      prop["organization"].should eq("Vandelay Industries")
    end
    respond_with 200, {
      type_name: "Lnl_Visitor",
      property_value_map: example_visitor.merge id: 1
    }
  end
  created_visitor = created_visitor.get.not_nil!
  created_visitor["id"]?.should eq(1)

  queried_visitor = exec(:lookup_visitor, email: "foo@bar.com")
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/instances")
    req.query_params["type_name"]?.should eq("Lnl_Visitor")
    req.query_params["filter"]?.should eq(%(email="foo@bar.com"))
    respond_with 200, {
      total_pages: 1,
      total_items: 1,
      count: 1,
      item_list: [{
        type_name: "Lnl_Visitor",
        property_value_map: example_visitor.merge id: 1
      }]
    }
  end
  queried_visitor = queried_visitor.get.not_nil!
  queried_visitor["id"]?.should eq(1)
  queried_visitor["firstname"]?.should eq("Kel")

  exec(:delete_visitor, id: 1)
  expect_http_request do |req, res|
    req.method.should eq("DELETE")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Visitor")
    body.dig("property_value_map", "id").should eq(1)
    res.status_code = 200
  end
end
