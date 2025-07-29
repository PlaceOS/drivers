require "placeos-driver/spec"
require "./origo_rest_api_models"

DriverSpecs.mock_driver "HID::OrigoRestApiDriver" do
  settings({
    client_id:      "test-client-id",
    client_secret:  "test-client-secret",
    application_id: "TEST-APP",
  })

  # Test authentication
  it "should authenticate successfully" do
    exec(:login)
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/authentication/customer/test/token"
      request.headers["Content-Type"].should eq "application/x-www-form-urlencoded"
      request.headers["Application-ID"].should eq "TEST-APP"
      request.headers["Application-Version"].should eq "1.0"

      body = URI::Params.parse(request.body.try(&.gets_to_end) || "")
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
end
