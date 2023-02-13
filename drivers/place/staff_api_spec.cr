require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::StaffAPI" do
  settings({
    # PlaceOS API creds, so we can query the zone metadata
    username:     "",
    password:     "",
    client_id:    "",
    redirect_uri: "",

    running_a_spec: true,
  })

  sleep 1
  resp = exec(:query_bookings, "desk")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Bearer spec-test"
      response.status_code = 200
      response << %([{
        "id": 1234,
        "user_id": "user-12345",
        "user_email": "steve@place.tech",
        "user_name": "Steve T",
        "asset_id": "desk-2-12",
        "zones": ["zone-build1", "zone-level2"],
        "booking_type": "Steve T",
        "booking_start": 123456,
        "booking_end": 12345678,
        "timezone": "Australia/Sydney",
        "checked_in": true,
        "rejected": false,
        "approved": false
      }])
    else
      response.status_code = 401
    end
  end

  resp.get.should eq(JSON.parse(%([{
      "id": 1234,
      "user_id": "user-12345",
      "user_email": "steve@place.tech",
      "user_name": "Steve T",
      "asset_id": "desk-2-12",
      "zones": ["zone-build1", "zone-level2"],
      "booking_type": "Steve T",
      "booking_start": 123456,
      "booking_end": 12345678,
      "timezone": "Australia/Sydney",
      "checked_in": true,
      "rejected": false,
      "approved": false
    }])))


  sleep 1
  invites_resp = exec(:get_survey_invites, sent: false)

  expect_http_request do |request, response|
    headers = request.headers
    if headers["Authorization"]? == "Bearer spec-test"
      response.status_code = 200

      params = request.query_params
      survey_id = params["survey_id"]? || 1234
      sent = params["sent"]?

      sent_invite = {
        id: 123,
        survey_id: survey_id,
        token: "QWERTY",
        email: "user@spec.test",
        sent: true,
      }
      unsent_invite = {
        id: 123,
        survey_id: survey_id,
        token: "QWERTY",
        email: "user@spec.test",
        sent: false,
      }

      if sent == "true"
        response << [sent_invite].to_json
      elsif sent == "false"
        response << [unsent_invite].to_json
      else
        response << [sent_invite, unsent_invite].to_json
      end
    else
      response.status_code = 401
    end
  end

  invites_resp.get.should eq(JSON.parse(%([{
      "id": 123,
      "survey_id": 1234,
      "token": "QWERTY",
      "email": "user@spec.test",
      "sent": false
    }])))
end
