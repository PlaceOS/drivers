require "placeos-driver/spec"

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
      session_token:         "abc123",
      token_expiration_time: "#{(Time.utc + 2.weeks).to_rfc3339}",
    }
  end

  # Re-auth on creds update
  settings({
    username:       "foo",
    password:       "bar",
    directory_id:   "baz",
    application_id: "",
  })
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/authentication")
    body = JSON.parse req.body.not_nil!
    body["user_name"].should eq("foo")
    body["password"].should eq("bar")
    body["directory_id"].should eq("baz")
    respond_with 200, {
      session_token:         "abc123",
      token_expiration_time: "#{(Time.utc + 2.weeks).to_rfc3339}",
    }
  end

  # Version lookup
  version = exec(:version)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/version")
    req.headers["Session-Token"]?.should eq("abc123")
    respond_with 200, {
      product_name:    "OnGuard 7.6",
      product_version: "7.6.001",
      version:         "1.0",
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
        code:    "openaccess.general.invalidapplicationid",
        message: "You are not licensed for OpenAccess.",
      },
    }
  end
  expect_raises(PlaceOS::Driver::RemoteException) do
    failing_request.get
  end

  # Cardholder CRUD

  example_cardholder = {
    email:     "sales@vandelayindustries.com",
    firstname: "Kel",
    lastname:  "Varnsen",
  }

  created_cardholder = exec(:create_cardholder, **example_cardholder)
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/count")
    req.query_params["type_name"]?.should eq("Lnl_Cardholder")
    req.query_params["filter"]?.should eq(%(email = "sales@vandelayindustries.com"))
    respond_with 200, {total_items: 0}
  end
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Cardholder")
    body["property_value_map"]?.try do |prop|
      prop["email"].should eq("sales@vandelayindustries.com")
      prop["firstname"].should eq("Kel")
      prop["lastname"].should eq("Varnsen")
    end
    respond_with 200, {
      type_name:          "Lnl_Cardholder",
      property_value_map: {
        ID: 1,
      },
    }
  end
  created_cardholder = created_cardholder.get.not_nil!
  created_cardholder["id"]?.should eq(1)

  queried_cardholder = exec(:lookup_cardholder, email: "sales@vandelayindustries.com")
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/instances")
    req.query_params["type_name"]?.should eq("Lnl_Cardholder")
    req.query_params["filter"]?.should eq(%(email = "sales@vandelayindustries.com"))
    respond_with 200, {
      total_pages: 1,
      total_items: 1,
      count:       1,
      type_name:   "Lnl_Cardholder",
      item_list:   [{
        property_value_map: {
          ID:        1,
          EMAIL:     "sales@vandelyindustries.com",
          FIRSTNAME: "Kel",
          LASTNAME:  "Varnsen",
        },
      }],
    }
  end
  queried_cardholder = queried_cardholder.get.not_nil!
  queried_cardholder["id"]?.should eq(1)
  queried_cardholder["firstname"]?.should eq("Kel")

  exec(:delete_cardholder, id: 1)
  expect_http_request do |req, res|
    req.method.should eq("DELETE")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Cardholder")
    body.dig("property_value_map", "id").should eq(1)
    res.status_code = 200
  end

  created_badge = exec(:create_badge, type: 5, personid: 1, id: 123)
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Badge")
    body["property_value_map"]?.try do |prop|
      prop["type"].should eq(5)
      prop["personid"].should eq(1)
      prop["id"].should eq(123)
    end
    respond_with 200, {
      type_name:          "Lnl_Badge",
      property_value_map: {
        BADGEKEY: 1,
      },
    }
  end
  created_badge = created_badge.get.not_nil!
  created_badge["badgekey"]?.should eq(1)

  exec(:delete_badge, badgekey: 1)
  expect_http_request do |req, res|
    req.method.should eq("DELETE")
    req.path.should eq("/instances")
    body = JSON.parse req.body.not_nil!
    body["type_name"]?.should eq("Lnl_Badge")
    body.dig("property_value_map", "badgekey").should eq(1)
    res.status_code = 200
  end
end
