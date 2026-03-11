require "placeos-driver/spec"

DriverSpecs.mock_driver "Orbility::ParkingRestAPI" do
  # Send the request
  retval = exec(:subscriptions, 6)

  # should send a login request
  expect_http_request do |_request, response|
    response.status_code = 200
    response << %({"userToken": "1234", "queryResult": true})
  end

  # then will expect the subscriptions
  expect_http_request do |_request, response|
    response.status_code = 200
    response << %({
  "subscriptions": [
    {
      "id": 2,
      "producId": 6,
      "offerId": null,
      "creationDate": "2026-02-26T18:52:16.45",
      "validityStartDate": "2025-04-17T00:00:00",
      "validityEndDate": "2030-04-16T23:59:59",
      "numberOfSpaces": 1,
      "numberOfCards": 1,
      "numberOfOccupiedSpaces": 0,
      "guaranteeAmount": 0,
      "amount": 0,
      "soldOnInternet": false,
      "creationTag": null,
      "contractNumber": 6,
      "cards": [
        2
      ]
    },
    {
      "id": 5,
      "producId": 6,
      "offerId": 3,
      "creationDate": "2026-03-03T13:48:35",
      "validityStartDate": "2025-04-17T00:00:00",
      "validityEndDate": "2050-01-01T00:00:01",
      "numberOfSpaces": 1,
      "numberOfCards": 1,
      "numberOfOccupiedSpaces": 0,
      "guaranteeAmount": 0,
      "amount": 0,
      "soldOnInternet": false,
      "creationTag": "ePs.SubscriberInterface",
      "contractNumber": 6,
      "cards": []
    },
    {
      "id": 7,
      "producId": 6,
      "offerId": 3,
      "creationDate": "2026-03-03T19:21:19.22",
      "validityStartDate": "2025-04-17T00:00:00",
      "validityEndDate": "2050-01-01T00:00:00",
      "numberOfSpaces": 1,
      "numberOfCards": 1,
      "numberOfOccupiedSpaces": 0,
      "guaranteeAmount": 0,
      "amount": 0,
      "soldOnInternet": false,
      "creationTag": "ePs.SubscriberInterface",
      "contractNumber": 6,
      "cards": []
    },
    {
      "id": 9,
      "producId": 6,
      "offerId": 3,
      "creationDate": "2026-03-04T08:16:28.811",
      "validityStartDate": "2026-02-25T09:46:28",
      "validityEndDate": "2056-03-04T09:46:28",
      "numberOfSpaces": 1,
      "numberOfCards": 1,
      "numberOfOccupiedSpaces": 0,
      "guaranteeAmount": 0,
      "amount": 0,
      "soldOnInternet": false,
      "creationTag": "ePs.SubscriberInterface",
      "contractNumber": 6,
      "cards": [
        9
      ]
    }
  ],
  "status": "OK",
  "queryResult": true,
  "message": null
})
  end

  result = retval.get.as_a.size > 0
  result.should be_true
end
