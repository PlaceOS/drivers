require "./instant_connect_models.cr"

DriverSpecs.mock_driver "Webex::InstantConnect" do
  # Send the request
  retval = exec(:create_meeting,
    room_id: "1",
    meeting_parameters: RAW_MEETING_PARAMETERS
  )

  # HTTP request to get host/guest hash
  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request.to_s.includes?(%("aud" => "a4d886b0-979f-4e2c-a958-3e8c14605e51")) && headers["Authorization"].includes?(%(Bearer))
        response.status_code = 200
        response << RAW_HASH_RESPONSE
      else
        response.status_code = 401
      end
    else
      raise "expected request to include aud & sub details #{request.inspect}"
    end
  end

  # HTTP request to get token using host JWT
  expect_http_request do |request, response|
    headers = request.headers
    if request.resource.includes?("api/v1/space/?int=jose&data=")
      response.status_code = 200
      response << RAW_TOKEN_RESPONSE
    else
      response.status_code = 401
    end
  end

  # final HTTP request to create meeting
  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request.to_s.includes?(%("title" => "Example Daily Meeting")) && headers["Authorization"].includes?(%(Bearer))
        response.status_code = 200
        response << RAW_MEETING_RESPONSE
      else
        response.status_code = 401
      end
    else
      raise "expected request to include meeting details #{request.inspect}"
    end
  end

  retval.get.to_json.should eq(RETVAL_RESPONSE)
end

RAW_TOKEN_RESPONSE = %({
  "userIdentifier": "Host",
  "isLoggedIn": false,
  "isHost": true,
  "organizationId": "16917798-5582-49a7-92d0-4410f6964000",
  "orgName": "PlaceOS",
  "token": "NmFmZGQwODYtZmIzNi00OTlmLWE3N2QtNzUyNzk2MDk4NDU5MjZlNmM2YmQtNjY2_PF84_e2d06a2e-ac4e-464f-968d-a5f8a5ac6303",
  "spaceId": "Y2lzY29zcGFyazovL3VzL1JPT00vODhhZGM1ODAtOThmMi0xMWVjLThiYjQtZjM2MmNkNDBlZDQ1",
  "visitId": "1",
  "integrationType": "jose"
})

RAW_MEETING_PARAMETERS = %({
  "title": "Example Daily Meeting",
  "agenda": "Example Agenda",
  "password": "BgJep@43",
  "start": "2019-11-01 20:00:00",
  "end": "2019-11-01 21:00:00",
  "timezone": "Asia/Shanghai",
  "recurrence": "FREQ=DAILY;INTERVAL=1;COUNT=10",
  "enabledAutoRecordMeeting": false,
  "allowAnyUserToBeCoHost": false,
  "enabledJoinBeforeHost": false,
  "enableConnectAudioBeforeHost": false,
  "joinBeforeHostMinutes": 0,
  "excludePassword": false,
  "publicMeeting": false,
  "reminderTime": 10,
  "enableAutomaticLock": false,
  "automaticLockMinutes": 0,
  "allowFirstUserToBeCoHost": false,
  "allowAuthenticatedDevices": false,
  "invitees": [
      {
          "email": "john.andersen@example.com",
          "displayName": "John Andersen",
          "coHost": false
      },
      {
          "email": "brenda.song@example.com",
          "displayName": "Brenda Song",
          "coHost": false
      }
  ],
  "sendEmail": true,
  "hostEmail": "john.andersen@example.com",
  "siteUrl": "site4-example.webex.com",
  "registration": {
      "requireFirstName": "true",
      "requireLastName": "true",
      "requireEmail": "true",
      "requireCompanyName": "true",
      "requireCountryRegion": "true",
      "requireWorkPhone": "true"
  },
  "integrationTags": [
      "dbaeceebea5c4a63ac9d5ef1edfe36b9",
      "85e1d6319aa94c0583a6891280e3437d",
      "27226d1311b947f3a68d6bdf8e4e19a1"
  ]
})

RAW_MEETING_RESPONSE = %({
  "id": "870f51ff287b41be84648412901e0402",
  "meetingNumber": "123456789",
  "title": "Example Daily Meeting",
  "agenda": "Example Agenda",
  "password": "BgJep@43",
  "phoneAndVideoSystemPassword": "12345678",
  "meetingType": "meetingSeries",
  "state": "active",
  "timezone": "Asia/Shanghai",
  "start": "2019-11-01T20:00:00+08:00",
  "end": "2019-11-01T21:00:00+08:00",
  "recurrence": "FREQ=DAILY;COUNT=10;INTERVAL=1",
  "hostUserId": "Y2lzY29zcGFyazovL3VzL1BFT1BMRS9jN2ZkNzNmMi05ZjFlLTQ3ZjctYWEwNS05ZWI5OGJiNjljYzY",
  "hostDisplayName": "John Andersen",
  "hostEmail": "john.andersen@example.com",
  "hostKey": "123456",
  "siteUrl": "site4-example.webex.com",
  "webLink": "https://site4-example.webex.com/site4/j.php?MTID=md41817da6a55b0925530cb88b3577b1e",
  "sipAddress": "123456789@site4-example.webex.com",
  "dialInIpAddress": "192.168.100.100",
  "enabledAutoRecordMeeting": false,
  "allowAnyUserToBeCoHost": false,
  "enabledJoinBeforeHost": false,
  "enableConnectAudioBeforeHost": false,
  "joinBeforeHostMinutes": 0,
  "excludePassword": false,
  "publicMeeting": false,
  "reminderTime": 10,
  "sessionTypeId": 3,
  "scheduledType": "meeting",
  "enableAutomaticLock": false,
  "automaticLockMinutes": 0,
  "allowFirstUserToBeCoHost": false,
  "allowAuthenticatedDevices": false,
  "telephony": {
      "accessCode": "1234567890",
      "callInNumbers": [
          {
              "label": "US Toll",
              "callInNumber": "123456789",
              "tollType": "toll"
          }
      ],
      "links": [
          {
              "rel": "globalCallinNumbers",
              "href": "/api/v1/meetings/870f51ff287b41be84648412901e0402/globalCallinNumbers",
              "method": "GET"
          }
      ]
  },
  "registration": {
      "autoAcceptRequest": "false",
      "requireFirstName": "true",
      "requireLastName": "true",
      "requireEmail": "true",
      "requireJobTitle": "false",
      "requireCompanyName": "true",
      "requireAddress1": "false",
      "requireAddress2": "false",
      "requireCity": "false",
      "requireState": "false",
      "requireZipCode": "false",
      "requireCountryRegion": "true",
      "requireWorkPhone": "true",
      "requireFax": "false"
  },
  "integrationTags": [
      "dbaeceebea5c4a63ac9d5ef1edfe36b9",
      "85e1d6319aa94c0583a6891280e3437d",
      "27226d1311b947f3a68d6bdf8e4e19a1"
  ]
})

RETVAL_RESPONSE = "{\"id\":\"870f51ff287b41be84648412901e0402\",\"meetingNumber\":\"123456789\",\"title\":\"Example Daily Meeting\",\"agenda\":\"Example Agenda\",\"password\":\"BgJep@43\",\"phoneAndVideoSystemPassword\":\"12345678\",\"meetingType\":\"meeting_series\",\"state\":\"active\",\"timezone\":\"Asia/Shanghai\",\"start\":\"2019-11-01T20:00:00+08:00\",\"end\":\"2019-11-01T21:00:00+08:00\",\"recurrence\":\"FREQ=DAILY;COUNT=10;INTERVAL=1\",\"hostUserId\":\"Y2lzY29zcGFyazovL3VzL1BFT1BMRS9jN2ZkNzNmMi05ZjFlLTQ3ZjctYWEwNS05ZWI5OGJiNjljYzY\",\"hostDisplayName\":\"John Andersen\",\"hostEmail\":\"john.andersen@example.com\",\"hostKey\":\"123456\",\"siteUrl\":\"site4-example.webex.com\",\"sipAddress\":\"123456789@site4-example.webex.com\",\"dialInIpAddress\":\"192.168.100.100\",\"enabledAutoRecordMeeting\":false,\"allowAnyUserToBeCoHost\":false,\"enabledJoinBeforeHost\":false,\"enableConnectAudioBeforeHost\":false,\"joinBeforeHostMinutes\":0,\"excludePassword\":false,\"publicMeeting\":false,\"reminderTime\":10,\"sessionTypeId\":3,\"scheduledType\":\"meeting\",\"enableAutomaticLock\":false,\"automaticLockMinutes\":0,\"allowFirstUserToBeCoHost\":false,\"allowAuthenticatedDevices\":false,\"telephony\":{\"accessCode\":\"1234567890\",\"callInNumbers\":[{\"label\":\"US Toll\",\"callInNumber\":\"123456789\",\"tollType\":\"toll\"}],\"links\":[{\"rel\":\"globalCallinNumbers\",\"href\":\"/api/v1/meetings/870f51ff287b41be84648412901e0402/globalCallinNumbers\",\"method\":\"GET\"}]},\"registration\":{\"autoAcceptRequest\":null,\"requireFirstName\":\"true\",\"requireLastName\":\"true\",\"requireEmail\":\"true\",\"requireJobTitle\":null,\"requireCompanyName\":\"true\",\"requireAddress1\":null,\"requireAddress2\":null,\"requireCity\":null,\"requireState\":null,\"requireZipCode\":null,\"requireCountryRegion\":\"true\",\"requireWorkPhone\":\"true\",\"requireFax\":null},\"integrationTags\":[\"dbaeceebea5c4a63ac9d5ef1edfe36b9\",\"85e1d6319aa94c0583a6891280e3437d\",\"27226d1311b947f3a68d6bdf8e4e19a1\"]}"

RAW_HASH_RESPONSE = %({
  "host": [
      "eyJwMnMiOiJCWXpoYmV4W"
  ],
  "guest": [
      "eyJwMnMiOiJaVVJsejNsb1"
  ]
})
