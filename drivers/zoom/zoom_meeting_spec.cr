require "placeos-driver/spec"
require "place_calendar"
require "jwt"

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  START_TIME = 1.hour.ago

  BOOKINGS = [
    PlaceCalendar::Event.new(
      id: "12345",
      host: "steve@place.com",
      event_start: START_TIME,
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

# :nodoc:
class ZoomAPIMock < DriverSpecs::MockDriver
  def meeting_join(room_id : String, meeting_number : String | Int64, password : String? = nil, host : Bool = false) : Nil
    logger.debug { "joining meeting #{meeting_number} in #{room_id}" }
  end

  def mute(room_id : String, state : Bool = true) : Nil
    logger.debug { "muting audio #{state} in #{room_id}" }
  end

  def video_mute(room_id : String, state : Bool = true) : Nil
    logger.debug { "muting video #{state} in #{room_id}" }
  end

  def share_content(room_id : String, state : Bool = true) : Nil
    logger.debug { "sharing content #{state} in #{room_id}" }
  end

  enum Role
    Participant = 0
    Host
  end

  def generate_jwt(meeting_number : String, issued_at : Int64? = nil, expires_at : Int64? = nil, role : Role? = nil)
    iat = issued_at || 2.minutes.ago.to_unix     # issued at time, 2 minutes earlier to avoid clock skew
    exp = expires_at || 2.hours.from_now.to_unix # token expires after 2 hours

    client_id = "key"
    payload = {
      "appKey"   => client_id,
      "mn"       => meeting_number,
      "role"     => (role || Role::Participant).to_i,
      "tokenExp" => exp,
      "iat"      => iat,
      "exp"      => exp,
    }

    JWT.encode(payload, "secret", JWT::Algorithm::HS256)
  end
end

DriverSpecs.mock_driver "Zoom::Meeting" do
  system({
    Bookings: {BookingsMock},
    ZoomAPI:  {ZoomAPIMock},
  })

  # ====
  # example generated at https://developers.zoom.us/docs/meeting-sdk/auth/
  # jwt = exec(:generate_jwt, "1234567", 1751266556_i64, 1751270156_i64, "host").get
  # jwt.should eq "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJhcHBLZXkiOiJrZXkiLCJzZGtLZXkiOiJrZXkiLCJtbiI6IjEyMzQ1NjciLCJyb2xlIjoxLCJ0b2tlbkV4cCI6MTc1MTI3MDE1NiwiaWF0IjoxNzUxMjY2NTU2LCJleHAiOjE3NTEyNzAxNTZ9.lbTc6uvEnxMBEq7WiJw9EnzXNdSU32qBAigXAvaIQ5I"

  # ====
  # join a meeting
  payload = exec(:join_meeting).get.not_nil!
  payload["password"]?.should eq "password"
  payload["meetingNumber"]?.should eq "123456789"
  payload["userEmail"]?.should eq "spec@acaprojects.com"
  payload["userName"]?.should eq "Spec Runner"

  jwt, header = JWT.decode(payload["signature"].as_s, "secret", JWT::Algorithm::HS256)
  jwt["appKey"].should eq "key"
  jwt["role"].should eq 1
  jwt["mn"].should eq "123456789"

  # ====
  # test link extraction
  ms_meeting = %(Join the meeting now<https://teams.microsoft.com/l/meetup-join/19%3ameeting_YzE1NzI3N2MtM200MGIxLWFhYTEtM2ViZTNlYjM5ZmY5%40thread.v2/0?context=%7b%22Tid%22%3a%225294a0-3e20-41b2-a970-6d0bf1546fa%22%2c%22Oid%22%3a%2257fc4f0c-fd53-4b12-8ca7-79ef698167f6%22%7d> Meeting ID: xxxxxxxxx5)
  exec(:extract_teams_link, ms_meeting).get.should eq "https://teams.microsoft.com/l/meetup-join/19%3ameeting_YzE1NzI3N2MtM200MGIxLWFhYTEtM2ViZTNlYjM5ZmY5%40thread.v2/0?context=%7b%22Tid%22%3a%225294a0-3e20-41b2-a970-6d0bf1546fa%22%2c%22Oid%22%3a%2257fc4f0c-fd53-4b12-8ca7-79ef698167f6%22%7d"

  google_meeting = %(Video call link: https://meet.google.com/sfq-nqpp-iqx Or)
  exec(:extract_meet_link, google_meeting).get.should eq "https://meet.google.com/sfq-nqpp-iqx"

  zoom_meeting = %(Join Zoom Meeting<https://ucla.zoom.us/j/93640805?pwd=P1BO3Il84TipdBd5Q.1&from=addon> One tap mobile:)
  exec(:extract_zoom_link, zoom_meeting).get.should eq "https://ucla.zoom.us/j/93640805?pwd=P1BO3Il84TipdBd5Q.1&from=addon"
end
