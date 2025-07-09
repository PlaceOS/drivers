require "placeos-driver/spec"
require "place_calendar"
require "jwt"

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  BOOKINGS = [
    PlaceCalendar::Event.new(
      id: "12345",
      host: "steve@place.com",
      event_start: 1.hour.ago,
      event_end: 2.hours.from_now,
      title: "Booking 1",
      body: "Some content\nmeeting: https://x.zoom.us/j/123456789?pwd=password\nwhat new line",
      location: "meeting 1",
      attendees: [PlaceCalendar::Event::Attendee.new(
        name: "Steve",
        email: "steve@place.com",
        response_status: "accepted",
        resource: false,
        organizer: true
      )],
      private: false,
      all_day: false,
      timezone: "Australia/Darwin",
      recurrence: nil,
      status: "confirmed",
      creator: "steve@place.com",
      recurring_event_id: nil,
      ical_uid: "some id",
      created: 3.days.ago,
      updated: 3.days.ago
    ),
  ]

  def on_load
    self[:bookings] = BOOKINGS
    self[:current_booking] = BOOKINGS[0]
  end
end

DriverSpecs.mock_driver "Zoom::Meeting" do
  system({
    Bookings: {BookingsMock},
  })

  # example generated at https://developers.zoom.us/docs/meeting-sdk/auth/
  jwt = exec(:generate_jwt, "1234567", 1751266556_i64, 1751270156_i64, "host").get
  jwt.should eq "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJhcHBLZXkiOiJrZXkiLCJzZGtLZXkiOiJrZXkiLCJtbiI6IjEyMzQ1NjciLCJyb2xlIjoxLCJ0b2tlbkV4cCI6MTc1MTI3MDE1NiwiaWF0IjoxNzUxMjY2NTU2LCJleHAiOjE3NTEyNzAxNTZ9.lbTc6uvEnxMBEq7WiJw9EnzXNdSU32qBAigXAvaIQ5I"

  payload = exec(:get_meeting).get.not_nil!
  payload["password"]?.should eq "password"
  payload["meetingNumber"]?.should eq "123456789"
  payload["userEmail"]?.should eq "spec@acaprojects.com"
  payload["userName"]?.should eq "Spec Runner"
  payload["sdkKey"]?.should eq "key"

  jwt, header = JWT.decode(payload["signature"].as_s, "secret", JWT::Algorithm::HS256)
  jwt["sdkKey"].should eq "key"
  jwt["role"].should eq 1
  jwt["mn"].should eq "123456789"

  status[:meeting_in_progress]?.should eq true
end
