require "placeos-driver/spec"
require "place_calendar"

DriverSpecs.mock_driver "Place::PublicEvents" do
  system({
    Bookings: {BookingsMock},
    Calendar: {CalendarMock},
  })

  # BookingsMock publishes its events in on_load, which triggers the
  # Bookings_1 :bookings subscription in our driver. Give it a moment to fire.
  sleep 200.milliseconds

  # -----------------------------------------------------------------------
  # Test 1: subscription populates the public events cache automatically
  # -----------------------------------------------------------------------
  events = status[:public_events].as_a
  events.size.should eq(1)
  events[0]["id"].as_s.should eq("evt-public-1")
  events[0]["title"].as_s.should eq("Public Conference")

  # -----------------------------------------------------------------------
  # Test 2: events without extended_properties.public are excluded
  # -----------------------------------------------------------------------
  events.none? { |e| e["id"].as_s == "evt-private-no-ext" }.should be_true

  # -----------------------------------------------------------------------
  # Test 3: events with extended_properties.public = false are excluded
  # -----------------------------------------------------------------------
  events.none? { |e| e["id"].as_s == "evt-private-explicit" }.should be_true

  # -----------------------------------------------------------------------
  # Test 4: only allowlisted fields are present in the public cache
  # -----------------------------------------------------------------------
  events[0]["event_start"].as_i64.should be > 0_i64
  events[0]["event_end"].as_i64.should be > 0_i64
  events[0]["attendees"]?.should be_nil
  events[0]["host"]?.should be_nil
  events[0]["body"]?.should be_nil
  events[0]["online_meeting_url"]?.should be_nil
  events[0]["creator"]?.should be_nil

  # -----------------------------------------------------------------------
  # Test 5: update_public_events triggers a Bookings re-poll and returns nil;
  # the cache is repopulated via the :bookings subscription binding.
  # -----------------------------------------------------------------------
  exec(:update_public_events).get
  sleep 200.milliseconds
  updated_events = status[:public_events].as_a
  updated_events.size.should eq(1)
  updated_events[0]["id"].as_s.should eq("evt-public-1")

  # -----------------------------------------------------------------------
  # Test 6: register_attendee appends the guest via the Calendar driver
  # -----------------------------------------------------------------------
  exec(:register_attendee, "evt-public-1", "Alice Smith", "alice@external.com").get.should be_true

  attendees = system(:Calendar)[:updated_attendees].as_a
  attendees.any? { |a| a["email"].as_s == "alice@external.com" }.should be_true
  attendees.any? { |a| a["name"].as_s == "Alice Smith" }.should be_true

  # -----------------------------------------------------------------------
  # Test 7: register_attendee returns false for unknown event IDs
  # -----------------------------------------------------------------------
  exec(:register_attendee, "evt-private-no-ext", "Bob", "bob@example.com").get.should be_false

  # Calendar must not have been called again — updated_attendees unchanged
  system(:Calendar)[:updated_attendees].as_a
    .none? { |a| a["email"].as_s == "bob@example.com" }
    .should be_true
end

# :nodoc:
# Simulates the Bookings driver. Publishes a fixed set of three events on load
# so the PublicEvents driver's subscription fires immediately:
#   - one explicitly public      (should appear in the cache)
#   - one with no properties     (should be excluded)
#   - one explicitly non-public  (should be excluded)
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    now = Time.utc
    self[:bookings] = [
      PlaceCalendar::Event.new(
        id: "evt-public-1",
        host: "organizer@company.com",
        title: "Public Conference",
        event_start: now + 1.day,
        event_end: now + 1.day + 2.hours,
        extended_properties: Hash(String, String?){"public" => "true"},
        attendees: [PlaceCalendar::Event::Attendee.new(name: "Internal Person", email: "internal@company.com")],
      ),
      PlaceCalendar::Event.new(
        id: "evt-private-no-ext",
        host: "team@company.com",
        title: "Internal Meeting",
        event_start: now + 2.days,
        event_end: now + 2.days + 1.hour,
      ),
      PlaceCalendar::Event.new(
        id: "evt-private-explicit",
        host: "exec@company.com",
        title: "Executive Briefing",
        event_start: now + 3.days,
        event_end: now + 3.days + 1.hour,
        extended_properties: Hash(String, String?){"public" => "false"},
      ),
    ]
  end

  def poll_events : Nil
    # Re-publish current bookings to exercise the subscription path.
    on_load
  end
end

# :nodoc:
# Simulates the Calendar driver (Microsoft::GraphAPI / Place::CalendarCommon).
# get_event returns a PlaceCalendar::Event directly.
# update_event records the final attendees list for assertion.
class CalendarMock < DriverSpecs::MockDriver
  def get_event(calendar_id : String, event_id : String, user_id : String? = nil) : PlaceCalendar::Event
    now = Time.utc
    PlaceCalendar::Event.new(
      id: event_id,
      host: calendar_id,
      title: "Public Conference",
      event_start: now + 1.day,
      event_end: now + 1.day + 2.hours,
    )
  end

  def update_event(event : PlaceCalendar::Event, user_id : String? = nil, calendar_id : String? = nil) : PlaceCalendar::Event
    self[:updated_attendees] = event.attendees
    event
  end
end
