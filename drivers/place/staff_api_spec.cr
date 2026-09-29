require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::StaffAPI" do
  resp = exec(:query_bookings, "desk")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-API-Key"]? == "spec-test"
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
    if headers["X-API-Key"]? == "spec-test"
      response.status_code = 200

      params = request.query_params
      survey_id = params["survey_id"]? || 1234
      sent = params["sent"]?

      sent_invite = {
        id:        123,
        survey_id: survey_id,
        token:     "QWERTY",
        email:     "user@spec.test",
        sent:      true,
      }
      unsent_invite = {
        id:        123,
        survey_id: survey_id,
        token:     "QWERTY",
        email:     "user@spec.test",
        sent:      false,
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

  sleep 1
  sync_resp = exec(:add_remove_ad_groups, "user-12345", ["ad-group-1", "ad-group-2"])

  expect_http_request do |request, response|
    request.method.should eq "POST"
    request.path.should eq "/api/engine/v2/groups/ad_groups/sync"
    request.headers["X-API-Key"]?.should eq "spec-test"
    request.headers["Content-Type"]?.should eq "application/json"

    body = JSON.parse(request.body.as(IO).gets_to_end)
    body["user_id"].should eq "user-12345"
    body["ad_groups"].should eq JSON.parse(%(["ad-group-1", "ad-group-2"]))

    response.status_code = 200
    response << %([{
      "user_id": "user-12345",
      "group_id": "0199a000-0000-7000-8000-000000000001",
      "permissions": 1,
      "auto_assigned": "ad-group-1"
    }])
  end

  sync_resp.get.should eq(JSON.parse(%([{
      "user_id": "user-12345",
      "group_id": "0199a000-0000-7000-8000-000000000001",
      "permissions": 1,
      "auto_assigned": "ad-group-1"
    }])))

  sleep 1
  failed_sync = exec(:add_remove_ad_groups, "user-missing", [] of String)

  expect_http_request do |_request, response|
    response.status_code = 404
  end

  expect_raises(PlaceOS::Driver::RemoteException) { failed_sync.get }
end
