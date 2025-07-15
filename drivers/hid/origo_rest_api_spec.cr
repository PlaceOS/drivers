require "placeos-driver/spec"
require "./origo_rest_api_models"

DriverSpecs.mock_driver "HID::OrigoRestApiDriver" do
  settings({
    organization_id: "test-org-123",
    client_id:       "test-client-id",
    client_secret:   "test-client-secret",
    application_id:  "TEST-APP",
  })

  # Test authentication
  it "should authenticate successfully" do
    exec(:login)
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/authentication/customer/test-org-123/token"
      request.headers["Content-Type"].should eq "application/json"
      request.headers["Application-ID"].should eq "TEST-APP"
      request.headers["Application-Version"].should eq "1.0"

      body = JSON.parse(request.body.not_nil!)
      body["client_id"].should eq "test-client-id"
      body["client_secret"].should eq "test-client-secret"
      body["grant_type"].should eq "client_credentials"

      response.status_code = 200
      response << {
        "access_token" => "test-token-123",
        "expires_in"   => 3600,
        "token_type"   => "Bearer",
      }.to_json
    end

    status["authenticated"].should eq true
    status["token_expires"]?.should_not be_nil
  end

  # Test user management
  it "should list users after authentication" do
    exec(:list_users)
    expect_http_request do |request, response|
      request.method.should eq "GET"
      request.path.should eq "/scim/organization/test-org-123/users"
      request.headers["Authorization"].should eq "Bearer test-token-123"
      request.headers["Application-ID"].should eq "TEST-APP"
      request.headers["Content-Type"].should eq "application/scim+json"
      request.headers["Accept"].should eq "application/scim+json"

      response.status_code = 200
      response << {
        "totalResults" => 2,
        "itemsPerPage" => 20,
        "startIndex"   => 0,
        "schemas"      => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
        "Resources"    => [
          {
            "id"          => "user-1",
            "userName"    => "john.doe",
            "displayName" => "John Doe",
            "active"      => true,
            "emails"      => [
              {
                "value"   => "john.doe@example.com",
                "primary" => true,
              },
            ],
          },
        ],
      }.to_json
    end
  end

  # Test user creation with structured data
  it "should create a user with structured data" do
    # Create a user object using the struct
    user = HID::User.new("new.user", "New User", true)
    user.emails = [HID::Email.from_json({"value" => "new.user@example.com", "primary" => true}.to_json)]
    user.schemas = ["urn:ietf:params:scim:schemas:core:2.0:User"]

    response = exec(:create_user, user)
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/scim/organization/test-org-123/users"
      request.headers["Authorization"].should eq "Bearer test-token-123"

      body = JSON.parse(request.body.not_nil!)
      body["userName"].should eq "new.user"
      body["displayName"].should eq "New User"
      body["active"].should eq true

      response.status_code = 201
      response << {
        "id"          => "user-new",
        "userName"    => "new.user",
        "displayName" => "New User",
        "active"      => true,
        "emails"      => [
          {
            "value"   => "new.user@example.com",
            "primary" => true,
          },
        ],
        "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "meta"    => {
          "created"      => "2023-07-19T04:50:59.995299Z",
          "lastModified" => "2023-07-19T04:50:59.995299Z",
          "location"     => "https://api.origo.hidglobal.com/scim/organization/test-org-123/users/user-new",
          "resourceType" => "User",
          "version"      => "W/\"0d2716cd61a5cec2e84fde59023cc0213\"",
        },
      }.to_json
    end
    response.get["id"].should eq "user-new"
  end

  # Test convenience method for creating basic users
  it "should create a basic user with convenience method" do
    exec(:create_basic_user, "jane.doe", "Jane Doe", "jane.doe@example.com")
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/scim/organization/test-org-123/users"
      request.headers["Authorization"].should eq "Bearer test-token-123"

      body = JSON.parse(request.body.not_nil!)
      body["userName"].should eq "jane.doe"
      body["displayName"].should eq "Jane Doe"
      body["active"].should eq true
      body["emails"].as_a[0]["value"].should eq "jane.doe@example.com"
      body["emails"].as_a[0]["primary"].should eq true

      response.status_code = 201
      response << {
        "id"          => "user-jane",
        "userName"    => "jane.doe",
        "displayName" => "Jane Doe",
        "active"      => true,
        "emails"      => [
          {
            "value"   => "jane.doe@example.com",
            "primary" => true,
          },
        ],
        "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      }.to_json
    end
  end

  # Test credential management
  it "should list passes after authentication" do
    exec(:list_passes)
    expect_http_request do |request, response|
      request.method.should eq "GET"
      request.path.should eq "/organization/test-org-123/pass"
      request.headers["Authorization"].should eq "Bearer test-token-123"
      request.headers["Application-ID"].should eq "TEST-APP"
      request.headers["Content-Type"].should eq "application/vnd.hidglobal.origo.credential-management-3.0+json"
      request.headers["Accept"].should eq "application/vnd.hidglobal.origo.credential-management-3.0+json"

      response.status_code = 200
      response << {
        "passes" => [
          {
            "id"     => "pass-1",
            "userId" => "user-1",
            "status" => "active",
          },
          {
            "id"     => "pass-2",
            "userId" => "user-2",
            "status" => "active",
          },
        ],
      }.to_json
    end
  end

  # Test pass creation with structured data
  it "should create a pass with structured data" do
    pass_request = HID::CreatePassRequest.new("user-1", "active")

    exec(:create_pass, pass_request)
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/organization/test-org-123/pass"
      request.headers["Authorization"].should eq "Bearer test-token-123"

      body = JSON.parse(request.body.not_nil!)
      body["userId"].should eq "user-1"
      body["status"].should eq "active"

      response.status_code = 201
      response << {
        "id"        => "pass-new",
        "userId"    => "user-1",
        "status"    => "active",
        "createdAt" => "2023-07-19T04:50:59.995299Z",
      }.to_json
    end
  end

  # Test convenience method for creating basic passes
  it "should create a basic pass with convenience method" do
    exec(:create_basic_pass, "user-1")
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/organization/test-org-123/pass"
      request.headers["Authorization"].should eq "Bearer test-token-123"

      body = JSON.parse(request.body.not_nil!)
      body["userId"].should eq "user-1"
      body["status"].should eq "active"

      response.status_code = 201
      response << {
        "id"        => "pass-basic",
        "userId"    => "user-1",
        "status"    => "active",
        "createdAt" => "2023-07-19T04:50:59.995299Z",
      }.to_json
    end
  end

  # Test pass status updates
  it "should suspend a pass" do
    exec(:suspend_pass, "pass-1")
    expect_http_request do |request, response|
      request.method.should eq "PUT"
      request.path.should eq "/organization/test-org-123/pass/pass-1"
      request.headers["Authorization"].should eq "Bearer test-token-123"

      body = JSON.parse(request.body.not_nil!)
      body["status"].should eq "suspended"

      response.status_code = 200
      response << {
        "id"        => "pass-1",
        "userId"    => "user-1",
        "status"    => "suspended",
        "updatedAt" => "2023-07-19T04:50:59.995299Z",
      }.to_json
    end
  end

  # Test authenticated check
  it "should check if authenticated" do
    result = exec(:authenticated?)
    result.get.should eq true
  end
end
