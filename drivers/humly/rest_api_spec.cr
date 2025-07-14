require "placeos-driver/spec"
require "./rest_api_models"

DriverSpecs.mock_driver "Humly::RestApiDriver" do
  settings({
    username: "testuser",
    password: "testpass",
  })

  # Test authentication - login once for all tests
  exec(:login)

  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/api/v1/login")
    response.status_code = 200
    response << {
      status: "success",
      data:   {
        userId:    "12345",
        authToken: "abc123token",
      },
    }.to_json
  end

  status["authenticated"]?.should eq(true)
  status["user_id"]?.should eq("12345")

  # Test get rooms - no login needed since we're already authenticated
  retval = exec(:get_rooms, limit: 10, offset: 0)

  expect_http_request do |request, response|
    request.method.should eq("GET")
    request.path.should eq("/api/v1/rooms")
    response.status_code = 200
    response << {
      status: "success",
      data:   [
        {
          _id:                        "1a2b3c4d5e6f7g8h",
          name:                       "Conference Room A",
          mail:                       "room1@humly.integration.com",
          address:                    "room1@humly.integration.com",
          id:                         "room1",
          numberOfSeats:              8,
          alias:                      "Conference Room A",
          isActive:                   true,
          bookingSystemSyncSupported: true,
          resourceType:               "room",
          bookingUri:                 nil,
          settings:                   {
            emailReminder:   false,
            timeZone:        "Europe/London",
            timeZoneCode:    "GMT0BST,M3.5.0/1,M10.5.0",
            allowGuestUsers: true,
            displaySettings: {
              organizer:    true,
              subject:      true,
              participants: true,
            },
            bookMeetingSettings: {
              enabled: true,
              auth:    true,
            },
            bookFutureMeetingSettings: {
              enabled: true,
              auth:    true,
            },
            endOngoingMeetingSettings: {
              enabled: true,
              auth:    false,
            },
          },
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil

  # Check response content using the correct pattern
  rooms = Array(Humly::RestApi::Room).from_json(result.to_json)
  rooms.size.should eq(1)
  rooms[0].name.should eq("Conference Room A")
  rooms[0].id.should eq("room1")
  rooms[0].numberOfSeats.should eq(8)
  rooms[0].resourceType.should eq("room")
  rooms[0].isActive.should be_true

  status["rooms"]?.should_not be_nil

  # Test get desks
  retval = exec(:get_desks, limit: 5)

  expect_http_request do |request, response|
    request.method.should eq("GET")
    request.path.should eq("/api/v1/desks")
    response.status_code = 200
    response << {
      status: "success",
      data:   [
        {
          _id:                        "1a2b3c4d5e6f7g8h",
          name:                       "Desk 001",
          mail:                       "desk1@humly.integration.com",
          address:                    "desk1@humly.integration.com",
          id:                         "desk1",
          numberOfSeats:              1,
          alias:                      "Desk 001",
          isActive:                   true,
          bookingSystemSyncSupported: true,
          resourceType:               "desk",
          bookingUri:                 nil,
          settings:                   {
            emailReminder:   false,
            timeZone:        "Europe/London",
            timeZoneCode:    "GMT0BST,M3.5.0/1,M10.5.0",
            allowGuestUsers: false,
            confirmDuration: "5",
            displaySettings: {
              organizer: true,
            },
            bookMeetingSettings: {
              enabled: true,
              auth:    false,
            },
            bookFutureMeetingSettings: {
              enabled: false,
              auth:    false,
            },
            endOngoingMeetingSettings: {
              enabled: true,
              auth:    false,
            },
          },
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil

  # Check response content using the correct pattern
  desks = Array(Humly::RestApi::Desk).from_json(result.to_json)
  desks.size.should eq(1)
  desks[0].name.should eq("Desk 001")
  desks[0].id.should eq("desk1")
  desks[0].numberOfSeats.should eq(1)
  desks[0].resourceType.should eq("desk")
  desks[0].isActive.should be_true

  status["desks"]?.should_not be_nil

  # Test create booking
  retval = exec(:create_booking,
    start_time: "2024-01-15T09:00:00Z",
    end_time: "2024-01-15T10:00:00Z",
    resource_id: "room1",
    title: "Test Meeting"
  )

  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/api/v1/bookings")
    response.status_code = 201
    response << {
      status: "success",
      data:   {
        _id:             "1a2b3c4d5e6f7g8h",
        id:              "booking123",
        changeKey:       "ABCDEFGHIJKL1234567890AB",
        source:          "HCP",
        eventIdentifier: "booking123_event",
        resourceId:      "room1",
        booking:         {
          startDate:         "2024-01-15T09:00:00Z",
          endDate:           "2024-01-15T10:00:00Z",
          location:          "Conference Room A",
          startTime:         "09:00",
          endTime:           "10:00",
          onlyDate:          "2024-01-15",
          dateForStatistics: "2024-01-15T09:00:00Z",
          createdBy:         {
            name: "HumlyIntegrationUser",
            mail: "HumlyIntegrationUser",
          },
          confirmed:   false,
          subject:     "Test Meeting",
          showConfirm: false,
          sensitivity: "Normal",
        },
      },
    }.to_json
  end

  result = retval.get
  result.should_not be_nil

  # Check response content using the correct pattern
  booking = Humly::RestApi::Booking.from_json(result.to_json)
  booking.id.should eq("booking123")
  booking.booking.subject.should eq("Test Meeting")
  booking.booking.startDate.should eq("2024-01-15T09:00:00Z")
  booking.booking.endDate.should eq("2024-01-15T10:00:00Z")
  booking.booking.confirmed.should be_false

  status["last_booking"]?.should_not be_nil

  # Test update booking
  retval = exec(:update_booking,
    booking_id: "booking123",
    title: "Updated Meeting"
  )

  expect_http_request do |request, response|
    request.method.should eq("PATCH")
    request.path.should eq("/api/v1/bookings/booking123")
    response.status_code = 200
    response << {
      status: "success",
      data:   {
        _id:             "1a2b3c4d5e6f7g8h",
        id:              "booking123",
        changeKey:       "ABCDEFGHIJKL1234567890AB",
        source:          "HCP",
        eventIdentifier: "booking123_event",
        resourceId:      "room1",
        booking:         {
          startDate:         "2024-01-15T09:00:00Z",
          endDate:           "2024-01-15T10:00:00Z",
          location:          "Conference Room A",
          startTime:         "09:00",
          endTime:           "10:00",
          onlyDate:          "2024-01-15",
          dateForStatistics: "2024-01-15T09:00:00Z",
          createdBy:         {
            name: "HumlyIntegrationUser",
            mail: "HumlyIntegrationUser",
          },
          confirmed:   false,
          subject:     "Updated Meeting",
          showConfirm: false,
          sensitivity: "Normal",
        },
      },
    }.to_json
  end

  result = retval.get
  result.should_not be_nil

  # Check response content using the correct pattern
  booking = Humly::RestApi::Booking.from_json(result.to_json)
  booking.id.should eq("booking123")
  booking.booking.subject.should eq("Updated Meeting")

  status["updated_booking"]?.should_not be_nil

  # Test delete booking
  retval = exec(:delete_booking, booking_id: "booking123")

  expect_http_request do |request, response|
    request.method.should eq("DELETE")
    request.path.should eq("/api/v1/bookings/booking123")
    response.status_code = 200
    response << {
      status: "success",
      data:   {message: "Booking deleted successfully"},
    }.to_json
  end

  result = retval.get
  result.should eq(true)
  status["last_deleted_booking"]?.should eq("booking123")

  # Test get devices
  retval = exec(:get_devices)

  expect_http_request do |request, response|
    request.method.should eq("GET")
    request.path.should eq("/api/v1/devices")
    response.status_code = 200
    response << {
      status: "success",
      data:   [
        {
          _id:                  "12345678ab",
          resourceId:           "a1b2c3d4e5f6",
          macAddress:           "11:22:33:44:55:66",
          isRebootable:         false,
          wentOfflineAt:        "2021-12-01T17:00:00+00:00",
          lastRebootTime:       "2021-12-01T06:56:00+00:00",
          lastConnectionTime:   "2021-12-01T06:58:27+00:00",
          macAddressWifi:       "aa:bb:cc:dd:ee:ff",
          ipAddress:            "127.0.0.1",
          secondIpAddress:      "Not available",
          interfaceActive:      "ethernet",
          serverIpAddress:      "127.0.0.1:3002",
          firmwareVersion:      "2021-11-01_v1.7.2.15",
          vncActive:            false,
          serialId:             "ABC123456",
          isPairingKeyApproved: true,
          deviceType:           "hrd1",
          status:               "online",
          name:                 "Panel 001",
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil

  # Check response content using the correct pattern
  devices = Array(Humly::RestApi::Device).from_json(result.to_json)
  devices.size.should eq(1)
  devices[0].name.should eq("Panel 001")
  devices[0].status.should eq("online")
  devices[0].deviceType.should eq("hrd1")
  devices[0].macAddress.should eq("11:22:33:44:55:66")
  devices[0].isRebootable.should be_false

  status["devices"]?.should_not be_nil
end
