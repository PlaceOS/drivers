require "placeos-driver/spec"
require "place_calendar"

DriverSpecs.mock_driver "Place::PublicEvents" do
  system({
    Bookings: {BookingsMock},
    Calendar: {CalendarMock},
    StaffAPI: {StaffAPIMock},
  })

  # BookingsMock publishes its events in on_load, which triggers the
  # Bookings_1 :bookings subscription in our driver. Give it a moment to fire.
  sleep 200.milliseconds

  # -----------------------------------------------------------------------
  # Test 1: subscription populates the public events cache automatically.
  #
  # evt-public-1 has a duplicate metadata pair: the real PUBLIC record with
  # ext_data, plus a newer PRIVATE webhook copy without ext_data. The record
  # with ext_data must win (mirroring the staff API's own resolution), so the
  # event still appears.
  # -----------------------------------------------------------------------
  events = status[:public_events].as_a
  event_ids = events.map { |event| event["id"].as_s }
  event_ids.should eq(["evt-public-1", "evt-series-instance", "evt-series-public-instance"])
  events[0]["title"].as_s.should eq("Public Conference")

  # -----------------------------------------------------------------------
  # Test 2: when every duplicate record carries ext_data, the most recently
  # written one wins (evt-private-meta: older PUBLIC + newer PRIVATE, both with
  # ext_data, so the event must stay excluded).
  # -----------------------------------------------------------------------
  event_ids.should_not contain("evt-private-meta")

  # -----------------------------------------------------------------------
  # Test 3: the permission field is not in the Bookings payload, so it has
  # to be fetched from the staff API
  # -----------------------------------------------------------------------
  queried = system(:StaffAPI)[:queried_refs].as_a.map(&.as_s)
  queried.size.should eq(queried.uniq.size)
  queried.should contain("evt-public-1")
  queried.should contain("uid-public-1")
  queried.should contain("evt-series-master")

  # -----------------------------------------------------------------------
  # Test 4: events without PUBLIC metadata permission are excluded
  # -----------------------------------------------------------------------
  # metadata says open (tenant users only, not the public)
  event_ids.should_not contain("evt-open-meta")
  # no metadata at all, defaults to private
  event_ids.should_not contain("evt-no-meta")

  # -----------------------------------------------------------------------
  # Test 5: instance metadata takes precedence over the recurring master
  # -----------------------------------------------------------------------
  # the master is PUBLIC but this instance has its own PRIVATE metadata
  event_ids.should_not contain("evt-series-instance-private")
  # a sibling instance being PUBLIC must not make the whole series public
  event_ids.should_not contain("evt-series-sibling")

  # -----------------------------------------------------------------------
  # Test 6: calendar private events are excluded, even when marked PUBLIC
  # (the Bookings driver has already masked the title and host)
  # -----------------------------------------------------------------------
  event_ids.should_not contain("evt-public-but-private-cal")

  # -----------------------------------------------------------------------
  # Test 7: only allowlisted fields are present in the public cache
  # -----------------------------------------------------------------------
  events[0]["event_start"].as_i64.should be > 0_i64
  events[0]["event_end"].as_i64.should be > 0_i64
  events[0]["body"]?.should_not be_nil
  events[0]["attendees"]?.should be_nil
  events[0]["host"]?.should be_nil
  events[0]["online_meeting_url"]?.should be_nil
  events[0]["creator"]?.should be_nil
  events[0]["private"]?.should be_nil
  events[0]["permission"]?.should be_nil
  events[0]["ical_uid"]?.should be_nil
  events[0]["recurring_event_id"]?.should be_nil

  # -----------------------------------------------------------------------
  # Test 8: update_public_events triggers a Bookings re-poll and re-checks the
  # metadata permissions.
  #
  # A permission can change without the events changing, and the Bookings
  # driver only publishes `bookings` when the value has changed, so the filter
  # must be re-applied regardless of the subscription firing.
  # StaffAPIMock marks `evt-no-meta` as PUBLIC (a record with no ext_data,
  # created outside Concierge) from the second query onwards.
  # -----------------------------------------------------------------------
  system(:StaffAPI)[:query_count].as_i.should eq(1)

  exec(:update_public_events).get
  sleep 200.milliseconds

  system(:StaffAPI)[:query_count].as_i.should eq(2)
  updated_events = status[:public_events].as_a
  updated_events.map { |event| event["id"].as_s }.should eq([
    "evt-public-1", "evt-no-meta", "evt-series-instance", "evt-series-public-instance",
  ])

  # -----------------------------------------------------------------------
  # Test 9: register_attendee appends the guest via the Calendar driver
  # -----------------------------------------------------------------------
  exec(:register_attendee, "evt-public-1", "Alice Smith", "alice@external.com").get.should be_true

  attendees = system(:Calendar)[:updated_attendees].as_a
  attendees.any? { |a| a["email"].as_s == "alice@external.com" }.should be_true
  attendees.any? { |a| a["name"].as_s == "Alice Smith" }.should be_true

  # -----------------------------------------------------------------------
  # Test 10: register_attendee returns false for events that are not public
  # -----------------------------------------------------------------------
  exec(:register_attendee, "evt-private-meta", "Bob", "bob@example.com").get.should be_false

  # Calendar must not have been called again — updated_attendees unchanged
  system(:Calendar)[:updated_attendees].as_a
    .none? { |a| a["email"].as_s == "bob@example.com" }
    .should be_true
end

# :nodoc:
# A staff API event metadata record, as returned by `query_metadata`
struct MetadataFixture
  include JSON::Serializable

  getter id : Int64?
  getter event_id : String
  getter ical_uid : String
  getter recurring_master_id : String?
  getter resource_master_id : String?
  getter permission : String
  getter ext_data : JSON::Any?
  getter updated_at : Int64

  def initialize(
    @event_id,
    @ical_uid,
    @permission,
    @id = nil,
    @recurring_master_id = nil,
    @resource_master_id = nil,
    @ext_data = nil,
    @updated_at = 0_i64,
  )
  end

  # mirrors the staff API `by_events_or_master_ids` lookup
  def matches?(refs : Array(String)) : Bool
    return true if refs.includes?(event_id) || refs.includes?(ical_uid)
    return true if (master = recurring_master_id) && refs.includes?(master)
    return true if (master = resource_master_id) && refs.includes?(master)
    false
  end
end

# :nodoc:
# Simulates the Bookings driver. Publishes a fixed set of events on load
# so the PublicEvents driver's subscription fires immediately.
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:bookings] = events
  end

  def poll_events : Nil
    # Re-publish the current bookings to exercise the subscription path.
    # NOTE:: the payload is stable, so a re-poll will not publish a change
    self[:bookings] = events
  end

  # built once so that re-polling doesn't change the payload
  private getter events : Array(PlaceCalendar::Event) do
    now = Time.utc
    [
      # metadata permission PUBLIC, should appear in the cache
      PlaceCalendar::Event.new(
        id: "evt-public-1",
        ical_uid: "uid-public-1",
        host: "organizer@company.com",
        title: "Public Conference",
        event_start: now + 1.day,
        event_end: now + 1.day + 2.hours,
        body: "Join us for the annual public conference.",
        attendees: [PlaceCalendar::Event::Attendee.new(name: "Internal Person", email: "internal@company.com")],
      ),
      # metadata permission PRIVATE
      PlaceCalendar::Event.new(
        id: "evt-private-meta",
        ical_uid: "uid-private-meta",
        host: "team@company.com",
        title: "Internal Meeting",
        event_start: now + 2.days,
        event_end: now + 2.days + 1.hour,
      ),
      # metadata permission OPEN (tenant users only)
      PlaceCalendar::Event.new(
        id: "evt-open-meta",
        ical_uid: "uid-open-meta",
        host: "team@company.com",
        title: "Lunch and Learn",
        event_start: now + 2.days,
        event_end: now + 2.days + 1.hour,
      ),
      # no metadata record exists for this event
      PlaceCalendar::Event.new(
        id: "evt-no-meta",
        ical_uid: "uid-no-meta",
        host: "exec@company.com",
        title: "Executive Briefing",
        event_start: now + 3.days,
        event_end: now + 3.days + 1.hour,
      ),
      # inherits the PUBLIC permission of the recurring master metadata
      PlaceCalendar::Event.new(
        id: "evt-series-instance",
        ical_uid: "uid-series-instance",
        recurring_event_id: "evt-series-master",
        host: "organizer@company.com",
        title: "Weekly Public Tour",
        event_start: now + 4.days,
        event_end: now + 4.days + 1.hour,
      ),
      # the master is PUBLIC, however this instance has its own PRIVATE metadata
      PlaceCalendar::Event.new(
        id: "evt-series-instance-private",
        ical_uid: "uid-series-instance-private",
        recurring_event_id: "evt-series-master",
        host: "organizer@company.com",
        title: "Weekly Public Tour (cancelled to the public)",
        event_start: now + 11.days,
        event_end: now + 11.days + 1.hour,
      ),
      # this instance is PUBLIC, its siblings are not
      PlaceCalendar::Event.new(
        id: "evt-series-public-instance",
        ical_uid: "uid-series-public-instance",
        recurring_event_id: "evt-series-master-2",
        host: "organizer@company.com",
        title: "Weekly Standup (open day)",
        event_start: now + 5.days,
        event_end: now + 5.days + 1.hour,
      ),
      PlaceCalendar::Event.new(
        id: "evt-series-sibling",
        ical_uid: "uid-series-sibling",
        recurring_event_id: "evt-series-master-2",
        host: "organizer@company.com",
        title: "Weekly Standup",
        event_start: now + 12.days,
        event_end: now + 12.days + 1.hour,
      ),
      # marked PUBLIC, but private on the calendar so title / host are masked
      PlaceCalendar::Event.new(
        id: "evt-public-but-private-cal",
        ical_uid: "uid-public-but-private-cal",
        host: "Private",
        title: "Private",
        event_start: now + 6.days,
        event_end: now + 6.days + 1.hour,
        private: true,
      ),
    ]
  end
end

# :nodoc:
# Simulates the staff API driver, returning event metadata for the requested
# event references. Note: the recurring master metadata is the record where
# `recurring_master_id == event_id`.
class StaffAPIMock < DriverSpecs::MockDriver
  EXT = JSON.parse(%({"view_access": "PUBLIC"}))

  METADATA = [
    # evt-public-1 has a duplicate pair (a race between the event create route
    # and the calendar webhook). The record with `ext_data` is the real one;
    # the webhook copy has none and defaults to PRIVATE even though it is the
    # most recently updated.
    MetadataFixture.new("evt-public-1", "uid-public-1", "public",
      id: 11, ext_data: EXT, updated_at: 1_787_628_000_i64),
    MetadataFixture.new("evt-public-1", "uid-public-1", "private",
      id: 12, ext_data: nil, updated_at: 1_787_630_000_i64),

    # evt-private-meta also has a duplicate pair, but both records carry
    # `ext_data`, so the most recently updated one wins.
    MetadataFixture.new("evt-private-meta", "uid-private-meta", "public",
      id: 21, ext_data: EXT, updated_at: 1_787_628_000_i64),
    MetadataFixture.new("evt-private-meta", "uid-private-meta", "private",
      id: 22, ext_data: EXT, updated_at: 1_787_629_000_i64),

    # metadata permission OPEN (tenant users only, not the public)
    MetadataFixture.new("evt-open-meta", "uid-open-meta", "open",
      id: 30, ext_data: JSON.parse(%({"view_access": "OPEN"})), updated_at: 1_787_628_000_i64),

    MetadataFixture.new("evt-series-master", "uid-series-master", "public",
      id: 40, recurring_master_id: "evt-series-master", resource_master_id: "res-series-master",
      ext_data: EXT, updated_at: 1_787_628_000_i64),

    MetadataFixture.new("evt-series-instance-private", "uid-series-instance-private", "private",
      id: 41, recurring_master_id: "evt-series-master",
      ext_data: EXT, updated_at: 1_787_628_000_i64),

    MetadataFixture.new("evt-series-public-instance", "uid-series-public-instance", "public",
      id: 42, recurring_master_id: "evt-series-master-2",
      ext_data: EXT, updated_at: 1_787_628_000_i64),

    MetadataFixture.new("evt-public-but-private-cal", "uid-public-but-private-cal", "public",
      id: 50, ext_data: EXT, updated_at: 1_787_628_000_i64),
  ]

  # simulates someone marking `evt-no-meta` as public after the initial lookup.
  # Note the record has no `ext_data` - events created outside Concierge may
  # have no extension data at all, so it must still be honoured.
  LATE_METADATA = MetadataFixture.new("evt-no-meta", "uid-no-meta", "public",
    id: 60, ext_data: nil, updated_at: 1_787_628_001_i64)

  @queries : Int32 = 0

  def query_metadata(
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    field_name : String? = nil,
    value : String? = nil,
    system_id : String? = nil,
    event_ref : Array(String)? = nil,
  ) : Array(MetadataFixture)
    refs = event_ref || [] of String
    @queries += 1
    self[:query_count] = @queries
    self[:queried_system_id] = system_id
    self[:queried_refs] = refs
    return [] of MetadataFixture if refs.empty?

    metadata = @queries > 1 ? METADATA + [LATE_METADATA] : METADATA
    metadata.select &.matches?(refs)
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
