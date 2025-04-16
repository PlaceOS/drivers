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
  channel_msgs_resp = exec(:list_channel_messages, team_id: "my_teams", channel_id: "my_channel")

  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-API-Key"]? == "spec-test" && request.path == "/api/staff/v1/teams/my_teams/my_channel"
      response.status_code = 200
      response << mock_get_channel_message.to_json
    end
  end

  channel_msgs_resp.get.should eq(JSON.parse(mock_get_channel_message.to_json))
end

def mock_get_channel_message
  %(
{
  "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#chats('19%3A8ea0e38b-efb3-4757-924a-5f94061cf8c2_97f62344-57dc-409c-88ad-c4af14158ff5%40unq.gbl.spaces')/messages/$entity",
  "id": "1612289992105",
  "replyToId": null,
  "etag": "1612289992105",
  "messageType": "message",
  "createdDateTime": "2021-02-02T18:19:52.105Z",
  "lastModifiedDateTime": "2021-02-02T18:19:52.105Z",
  "lastEditedDateTime": null,
  "deletedDateTime": null,
  "subject": null,
  "summary": null,
  "chatId": "19:8ea0e38b-efb3-4757-924a-5f94061cf8c2_97f62344-57dc-409c-88ad-c4af14158ff5@unq.gbl.spaces",
  "importance": "normal",
  "locale": "en-us",
  "webUrl": null,
  "channelIdentity": null,
  "policyViolation": null,
  "eventDetail": null,
  "from": {
      "application": null,
      "device": null,
      "conversation": null,
      "user": {
          "@odata.type": "#microsoft.graph.teamworkUserIdentity",
          "id": "8ea0e38b-efb3-4757-924a-5f94061cf8c2",
          "displayName": "Robin Kline",
          "userIdentityType": "aadUser",
          "tenantId": "e61ef81e-8bd8-476a-92e8-4a62f8426fca"
      }
  },
  "body": {
      "contentType": "text",
      "content": "test"
  },
  "attachments": [],
  "mentions": [],
  "reactions": [],
  "messageHistory": []
}
  )
end
