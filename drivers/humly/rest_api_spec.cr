require "placeos-driver/spec"

DriverSpecs.mock_driver "Humly::RestApi" do
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
          id:   "room1",
          name: "Conference Room A",
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil
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
          id:   "desk1",
          name: "Desk 001",
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil
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
        id:         "booking123",
        startTime:  "2024-01-15T09:00:00Z",
        endTime:    "2024-01-15T10:00:00Z",
        resourceId: "room1",
        title:      "Test Meeting",
      },
    }.to_json
  end

  result = retval.get
  result.should_not be_nil
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
        id:    "booking123",
        title: "Updated Meeting",
      },
    }.to_json
  end

  result = retval.get
  result.should_not be_nil
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
          id:     "device1",
          name:   "Panel 001",
          type:   "touch_panel",
          status: "online",
        },
      ],
    }.to_json
  end

  result = retval.get
  result.should_not be_nil
  status["devices"]?.should_not be_nil
end