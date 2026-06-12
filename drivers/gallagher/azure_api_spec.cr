require "./rest_api_models"
require "placeos-driver/spec"

DriverSpecs.mock_driver "Gallagher::AzureAPI" do
  # wait for the startup auth attempts (against the placeholder default
  # settings) to conclude - they can't succeed and mark the driver offline,
  # the settings update below then resets the failed authentication state
  timeout = 120
  while status[:authentication]?.nil?
    sleep 500.milliseconds
    timeout -= 1
    raise "startup authentication never concluded" if timeout.zero?
  end

  # token endpoint is relative so the grant requests are routed to the mock server
  settings({
    azure_apim_subscription: "sub-key",
    azure_tenant_id:         "tenant-id",
    azure_client_id:         "client-id",
    azure_client_secret:     "client-secret",
    azure_scopes:            "api://gallagher/.default",
    azure_token_endpoint:    "/oauth/token",
    unique_pdf_name:         "email",
  })

  # ===========================
  # happy path authentication
  # ===========================
  auth = exec(:ensure_authenticated)
  expect_http_request do |request, response|
    request.path.should eq "/oauth/token"
    body = request.body.try(&.gets_to_end) || ""
    body.should contain "grant_type=client_credentials"
    body.should contain "client_id=client-id"
    body.should contain "client_secret=client-secret"

    response.status_code = 200
    response << {access_token: "token-1", token_type: "Bearer", expires_in: 3599}.to_json
  end
  auth.get
  status[:authentication].should eq "authenticated"

  # coming back online re-runs the connected callback, absorb its endpoints
  # query (an error response keeps the event monitor out of this spec)
  expect_http_request do |request, response|
    request.path.should eq "/"
    response.status_code = 500
  end

  # ====================================================
  # a 401 response triggers re-auth + replays the request
  # ====================================================
  cardholder = exec(:get_cardholder, "1234")

  # token was revoked early
  expect_http_request do |request, response|
    request.path.should eq "/cardholders/1234/"
    request.headers["Authorization"]?.should eq "Bearer token-1"
    request.headers["Ocp-Apim-Subscription-Key"]?.should eq "sub-key"
    response.status_code = 401
  end

  # the driver re-authenticates
  expect_http_request do |request, response|
    request.path.should eq "/oauth/token"
    response.status_code = 200
    response << {access_token: "token-2", token_type: "Bearer", expires_in: 3599}.to_json
  end

  # and replays the request with the new token
  expect_http_request do |request, response|
    request.path.should eq "/cardholders/1234/"
    request.headers["Authorization"]?.should eq "Bearer token-2"
    response.status_code = 200
    response << %({"id": "1234", "firstName": "Bob", "lastName": "Builder"})
  end

  result = Gallagher::Cardholder.from_json(cardholder.get.to_json)
  result.id.should eq "1234"
  result.first_name.should eq "Bob"
  status[:authentication].should eq "authenticated"

  # ==========================================================
  # more than 2 token grant failures marks the driver offline
  # ==========================================================
  failed = exec(:renew_authentication)
  3.times do
    expect_http_request do |request, response|
      request.path.should eq "/oauth/token"
      response.status_code = 401
      response << %({"error": "invalid_client"})
    end
  end
  expect_raises(Exception, /error authenticating/) { failed.get }

  status[:authentication].as_s.should start_with "failed:"
  status[:connected].should eq false

  # while in the failed state, requests don't hit the network
  # (a stray request here would stall unanswered and time the spec out)
  blocked = exec(:get_cardholder, "999")
  expect_raises(Exception, /authentication suspended/) { blocked.get }

  # ===========================================================
  # updating settings (e.g. rotated credentials) allows recovery
  # ===========================================================
  settings({
    azure_apim_subscription: "sub-key",
    azure_tenant_id:         "tenant-id",
    azure_client_id:         "client-id",
    azure_client_secret:     "rotated-secret",
    azure_scopes:            "api://gallagher/.default",
    azure_token_endpoint:    "/oauth/token",
    unique_pdf_name:         "email",
  })

  recovered = exec(:ensure_authenticated)
  expect_http_request do |request, response|
    request.path.should eq "/oauth/token"
    body = request.body.try(&.gets_to_end) || ""
    body.should contain "client_secret=rotated-secret"
    response.status_code = 200
    response << {access_token: "token-3", token_type: "Bearer", expires_in: 3599}.to_json
  end
  recovered.get
  status[:authentication].should eq "authenticated"
  status[:connected].should eq true

  # recovery transitioned offline -> online, absorb the endpoints query
  expect_http_request do |request, response|
    request.path.should eq "/"
    response.status_code = 500
  end

  # ===================================================================
  # persistent 401s despite valid tokens (bad APIM key) marks us offline
  # without spamming the token endpoint (forced re-auth is throttled)
  # ===================================================================
  3.times do
    request = exec(:get_cardholder, "42")
    expect_http_request do |req, response|
      req.path.should eq "/cardholders/42/"
      response.status_code = 401
    end
    expect_raises(Exception, /cardholder request failed with 401/) { request.get }
  end

  status[:authentication].as_s.should contain "APIM subscription key"
  status[:connected].should eq false

  # requests remain blocked until the scheduled auth retry
  blocked = exec(:get_cardholder, "7")
  expect_raises(Exception, /authentication suspended/) { blocked.get }
end
