require "placeos-driver/spec"
require "./origo_rest_api_models"

DriverSpecs.mock_driver "HID::OrigoRestApiDriver" do
  settings({
    client_id:      "test-client-id",
    client_secret:  "test-client-secret",
    application_id: "TEST-APP",
    default_part:   "MID-SUB-CRD_FTPN_6445",
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

  # Test getting a part
  it "should obtain some part details" do
    resp = exec(:get_part, "4924_644243")
    expect_http_request do |request, response|
      request.method.should eq "GET"
      request.path.should eq "/credential-management/customer/test/part-number/4924_644243"

      response.status_code = 200
      response << %({
        "schemas": [
          "urn:hid:scim:api:ma:2.2:PartNumber"
        ],
        "urn:hid:scim:api:ma:2.2:PartNumber": [
          {
            "meta": {
              "resourceType": "PartNumber",
              "lastModified": "2017-12-03T14:03:25Z",
              "location": "https://cert.mi.api.origo.hidglobal.com/credential-management/customer/test/part-number/4924_644243"
            },
            "id": "4924_644243",
            "partNumber": "MID-SUB-CRD_FTPN_644245",
            "friendlyName": "MOB0022",
            "availableQty": 445,
            "offset": 0,
            "prefix": "",
            "suffix": "",
            "nextNumber": 56,
            "lastNumber": 500,
            "badge_type": "FTPN",
            "programmingData": {
              "facility code": "99",
              "incremental_card id number": "1",
              "format_number": "TRK-H10301"
            },
            "replenishmentState": "Not Needed"
          }
        ]
      })
    end

    resp.get["partNumber"].should eq "MID-SUB-CRD_FTPN_644245"
  end

  it "should invite a user to use a virtual card" do
    resp = exec(:invite_user_email, "steve@example.com")
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/credential-management/customer/test/users/.search"

      response.status_code = 200
      response << %({
        "schemas": [
          "urn:ietf:params:scim:api:messages:2.0:ListResponse"
        ],
        "totalResults": 1,
        "itemsPerPage": 1,
        "startIndex": 1,
        "Resources": [
          {
            "meta": {
              "resourceType": "PACSUser",
              "lastModified": "2024-05-28T04:49:59Z",
              "location": "https://cert.mi.api.origo.hidglobal.com/credential-management/customer/test/users/103367"
            },
            "name": {
              "familyName": "Doe",
              "givenName": "John"
            },
            "emails": [
              {
                "value": "steve@example.com"
              }
            ]
          }
        ]
      })
    end

    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/credential-management/customer/test/users/103367/invitation"

      response.status_code = 200
      response << %({
        "schemas": [
          "urn:hid:scim:api:ma:2.2:UserInvitation",
          "urn:hid:scim:api:ma:2.2:Credential"
        ],
        "urn:hid:scim:api:ma:2.2:UserInvitation": [
          {
            "meta": {
              "resourceType": "UserInvitation",
              "lastModified": "2025-07-30T03:29:15Z",
              "location": "https://cert.mi.api.origo.hidglobal.com/credential-management/customer/test/invitation/16257463"
            },
            "id": 16247463,
            "invitationCode": "BPEX-LQTC-4E33-QT6N",
            "status": "PENDING",
            "createdDate": "2025-07-30T03:29:15Z",
            "expirationDate": "2025-08-01T03:29:15Z"
          }
        ],
        "urn:hid:scim:api:ma:2.2:Credential": [
          {
            "id": 304530,
            "partNumber": "MID-SUB-CRD_FTPN_6445",
            "partnumberFriendlyName": "MOB0022",
            "status": "ISSUE_INITIATED",
            "credentialType": "ICLASSSEOS",
            "cardNumber": "56"
          }
        ]
      })
    end

    values = resp.get
    values[0]["invitationCode"].should eq "BPEX-LQTC-4E33-QT6N"
    values[1]["partNumber"].should eq "MID-SUB-CRD_FTPN_6445"
  end
end
