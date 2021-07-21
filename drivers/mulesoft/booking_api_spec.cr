require "placeos-driver/spec"

DriverSpecs.mock_driver "MuleSoft::API" do
  settings({
    venue_code:         "venue code",
    base_path:          "/usyd-edu-timetable-exp-api-v1/v1/",
    polling_period:     5,
    time_zone:          "Australia/Sydney",
    ssl_key:            "private key",
    ssl_cert:           "certificate",
    ssl_auth_enabled:   false,
    username:           "basic auth username",
    password:           "basic auth password",
    basic_auth_enabled: false,
    running_a_spec:     true,
  })

  resp = exec(:query_bookings, "A14.02.K2.05")

  expect_http_request do |_request, response|
    starts_at = Time.local - 30.minutes
    ends_at = starts_at + 1.hour

    response.status_code = 200
    response << <<-RESPONSE
                {
                  "count": 1,
                  "timeTableBookingsCount": 1,
                  "casualBookingsCount": 0,
                  "venueCode": "A14.02.K2.05",
                  "venueName": "A14.02.K2.05.The Quadrangle.The Quad General Lecture Theatre K2.05",
                  "bookings": [
                    {
                      "unitCode": "HSTY2630",
                      "unitName": "Panics and Pandemics",
                      "activityName": "HSTY2630-S1C-ND-CC/TUT/01",
                      "activityType": "Tutorial",
                      "activityDescription": "Tutorial",
                      "startDateTime": "#{starts_at.to_s("%FT%T")}",
                      "endDateTime": "#{ends_at.to_s("%FT%T")}",
                      "location": "Social Sciences Building - SSB Seminar Room 210",
                      "bookingType": "timeTable"
                    }
                  ]
                }
                RESPONSE
  end

  resp.get

  exec(:check_current_booking).get
end
