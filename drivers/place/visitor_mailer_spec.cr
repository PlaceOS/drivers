require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  def on_load
    self[:send_count] = 0
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : (String | Array(String))? = nil,
    reply_to : (String | Array(String))? = nil,
  )
    self[:last_to] = to
    self[:last_template] = template
    self[:last_args] = args
    self[:send_count] = self[:send_count].as_i + 1
    true
  end

  def send_mail(
    to : String | Array(String),
    subject : String,
    message_plaintext : String? = nil,
    message_html : String? = nil,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : (String | Array(String))? = nil,
    reply_to : (String | Array(String))? = nil,
  ) : Bool
    true
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_user(email : String)
    {name: "Host User", email: email}
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  BUILDING_ZONE = {
    id:           "zone-building",
    name:         "Main Building",
    display_name: "Main Building",
    location:     "",
    tags:         ["building"],
    parent_id:    "zone-org",
  }

  OLD_BUILDING_ZONE = {
    id:           "zone-old-building",
    name:         "Old Building",
    display_name: "Previous Building",
    location:     "",
    tags:         ["building"],
    parent_id:    "zone-org",
  }

  ROOM_ZONE = {
    id:           "zone-room",
    name:         "Room 101",
    display_name: "Conference Room 101",
    location:     "",
    tags:         ["level"],
    parent_id:    "zone-building",
  }

  OLD_ROOM_ZONE = {
    id:           "zone-old-room",
    name:         "Room 202",
    display_name: "Previous Room 202",
    location:     "",
    tags:         ["level"],
    parent_id:    "zone-old-building",
  }

  EXTRA_ZONE = {
    id:           "zone-extra",
    name:         "Extra Zone",
    display_name: "Extra Zone",
    location:     "",
    tags:         ["org"],
    parent_id:    nil,
  }

  def on_load
    self[:zone_lookups] = 0
  end

  def zone(id : String)
    self[:zone_lookups] = self[:zone_lookups].as_i + 1
    case id
    when "zone-building"
      BUILDING_ZONE
    when "zone-old-building"
      OLD_BUILDING_ZONE
    when "zone-room"
      ROOM_ZONE
    when "zone-old-room"
      OLD_ROOM_ZONE
    when "zone-extra"
      EXTRA_ZONE
    else
      # Return a generic zone tagged as building so on_load find_building succeeds
      BUILDING_ZONE
    end
  end

  def booking_guests(booking_id : Int64)
    [
      {
        email:          "visitor@external.com",
        name:           "Visitor One",
        checked_in:     false,
        visit_expected: true,
      },
    ]
  end

  def event_guests(event_id : String, system_id : String)
    [
      {
        email:          "visitor@external.com",
        name:           "Visitor One",
        checked_in:     false,
        visit_expected: true,
      },
    ]
  end
end

DriverSpecs.mock_driver "Place::VisitorMailer" do
  system({
    StaffAPI: {StaffAPIMock},
    Mailer:   {MailerMock},
    Calendar: {CalendarMock},
  })

  # Allow on_load -> on_update -> ensure_building_zone to complete
  sleep 1.5

  # ------------------------------------------------------------------
  # Test 1: booking_changed with previous_zones resolves names correctly
  # ------------------------------------------------------------------

  now = Time.utc.to_unix

  changed_payload_with_zones = {
    action:                 "changed",
    id:                     100_i64,
    booking_type:           "desk",
    booking_start:          now + 3600,
    booking_end:            now + 7200,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Team Meeting",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now,
    previous_booking_end:   now + 3600,
    previous_zones:         ["zone-old-building", "zone-old-room"],
  }.to_json

  # Ensure zone lookup counters are initialized before publishing
  system(:StaffAPI)[:zone_lookups].should_not be_nil

  publish("staff/booking/changed", changed_payload_with_zones)
  sleep 1.5

  # Verify email was sent
  system(:Mailer)[:send_count].should eq 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # Verify the template args include resolved previous location names
  args = system(:Mailer)[:last_args]
  args["previous_building_name"].should eq "Previous Building"
  args["previous_room_name"].should eq "Previous Room 202"

  # Verify current location names are from the current building/room
  args["building_name"].should eq "Main Building"
  args["room_name"].should eq "Client Floor"

  # Verify host name was resolved
  args["host_name"].should eq "Host User"
  args["host_email"].should eq "host@example.com"
  args["event_title"].should eq "Team Meeting"

  # ------------------------------------------------------------------
  # Test 2: booking_changed with only time change (no previous_zones)
  #         should use default building/room names
  # ------------------------------------------------------------------

  changed_payload_time_only = {
    action:                 "changed",
    id:                     101_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Standup",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now,
    previous_booking_end:   now + 3600,
    # No previous_zones — location did not change
  }.to_json

  publish("staff/booking/changed", changed_payload_time_only)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 2

  args2 = system(:Mailer)[:last_args]
  # Without previous_zones the driver falls back to the current building name and @booking_space_name
  args2["previous_building_name"].should eq "Main Building"
  args2["previous_room_name"].should eq "Client Floor"
  args2["event_title"].should eq "Standup"

  # previous_event_date and previous_event_time should be present (time did change)
  args2["previous_event_date"].should_not be_nil
  args2["previous_event_time"].should_not be_nil

  # ------------------------------------------------------------------
  # Test 3: action != "changed" is ignored (no extra email sent)
  # ------------------------------------------------------------------

  created_payload = {
    action:        "create",
    id:            102_i64,
    booking_type:  "desk",
    booking_start: now + 3600,
    booking_end:   now + 7200,
    timezone:      "GMT",
    resource_id:   "desk-1",
    resource_ids:  ["desk-1"],
    user_email:    "host@example.com",
    title:         "Ignored Event",
    zones:         ["zone-building"],
  }.to_json

  publish("staff/booking/changed", created_payload)
  sleep 0.5

  # Count should not have increased
  system(:Mailer)[:send_count].should eq 2

  # ------------------------------------------------------------------
  # Test 4: Zone caching — zone-old-building and zone-old-room were
  #         already looked up (and cached) in Test 1, so repeating them
  #         here should require zero new API calls.
  # ------------------------------------------------------------------

  lookups_before = system(:StaffAPI)[:zone_lookups].as_i

  changed_payload_short_circuit = {
    action:                 "changed",
    id:                     103_i64,
    booking_type:           "desk",
    booking_start:          now + 3600,
    booking_end:            now + 7200,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Short Circuit Test",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now,
    previous_booking_end:   now + 3600,
    # Building first, room second, extra third — extra should be skipped
    previous_zones: ["zone-old-building", "zone-old-room", "zone-extra"],
  }.to_json

  publish("staff/booking/changed", changed_payload_short_circuit)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 3

  lookups_after = system(:StaffAPI)[:zone_lookups].as_i
  # zone-old-building and zone-old-room are served from the zone cache
  # (populated during Test 1), so no new API calls are made.
  # The third zone (zone-extra) is never reached due to short-circuit.
  previous_zone_lookups = lookups_after - lookups_before
  previous_zone_lookups.should eq 0

  # Verify the resolved names are still correct
  args3 = system(:Mailer)[:last_args]
  args3["previous_building_name"].should eq "Previous Building"
  args3["previous_room_name"].should eq "Previous Room 202"

  # ------------------------------------------------------------------
  # Test 5: Event for a different building is ignored
  # ------------------------------------------------------------------

  changed_payload_wrong_zone = {
    action:                 "changed",
    id:                     104_i64,
    booking_type:           "desk",
    booking_start:          now + 3600,
    booking_end:            now + 7200,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Wrong Zone",
    zones:                  ["zone-other-building"],
    previous_booking_start: now,
    previous_booking_end:   now + 3600,
  }.to_json

  publish("staff/booking/changed", changed_payload_wrong_zone)
  sleep 0.5

  # Count should not have increased — event was for a different building
  system(:Mailer)[:send_count].should eq 3

  # ------------------------------------------------------------------
  # Test 6: No fields actually changed — should not send email
  # ------------------------------------------------------------------

  changed_payload_no_diff = {
    action:        "changed",
    id:            105_i64,
    booking_type:  "desk",
    booking_start: now + 3600,
    booking_end:   now + 7200,
    timezone:      "GMT",
    resource_id:   "desk-1",
    resource_ids:  ["desk-1"],
    user_email:    "host@example.com",
    title:         "No Real Change",
    zones:         ["zone-building", "zone-room"],
    # Same start time as current — no actual change
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
    # No previous_zones — no location change
  }.to_json

  publish("staff/booking/changed", changed_payload_no_diff)
  sleep 0.5

  system(:Mailer)[:send_count].should eq 3

  # ------------------------------------------------------------------
  # Test 6b: booking_changed with "metadata_changed" action but time
  #          window actually shrunk (e.g. 9am–5pm → 10am–4pm).
  #          The driver should still send the notification because the
  #          previous values differ from the current values.
  # ------------------------------------------------------------------

  changed_payload_shrunk = {
    action:                 "metadata_changed",
    id:                     106_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Shrunk Window Meeting",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 14400,
  }.to_json

  publish("staff/booking/changed", changed_payload_shrunk)
  sleep 1.5

  # Even though the action is "metadata_changed", the time genuinely
  # changed so visitors must be notified.
  system(:Mailer)[:send_count].should eq 4
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]
  system(:Mailer)[:last_args]["event_title"].should eq "Shrunk Window Meeting"

  # ==================================================================
  # booking_host_changed_event tests
  # ==================================================================

  # ------------------------------------------------------------------
  # Test 7: booking_host_changed — sends email to previous host
  # ------------------------------------------------------------------

  host_changed_payload = {
    action:              "host_changed",
    booking_id:          200_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_title:         "Team Standup",
    event_summary:       "Team Standup Description",
    event_starting:      now + 3600,
    previous_host_email: "old-host@example.com",
    new_host_email:      "new-host@example.com",
    zones:               ["zone-building", "zone-room"],
  }.to_json

  publish("staff/booking/host_changed", host_changed_payload)
  sleep 1.5

  # Email should be sent to the previous host
  system(:Mailer)[:send_count].should eq 5
  system(:Mailer)[:last_to].should eq "old-host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  # Verify all template args
  args7 = system(:Mailer)[:last_args]
  args7["previous_host_email"].should eq "old-host@example.com"
  args7["previous_host_name"].should eq "Host User"
  args7["new_host_email"].should eq "new-host@example.com"
  args7["new_host_name"].should eq "Host User"
  args7["building_name"].should eq "Main Building"
  args7["event_title"].should eq "Team Standup"
  args7["event_date"].should_not be_nil
  args7["event_time"].should_not be_nil

  # ------------------------------------------------------------------
  # Test 8: booking_host_changed — wrong zone is ignored
  # ------------------------------------------------------------------

  host_changed_wrong_zone = {
    action:              "host_changed",
    booking_id:          201_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_title:         "Wrong Zone Meeting",
    event_summary:       "Wrong Zone Meeting",
    event_starting:      now + 3600,
    previous_host_email: "old-host@example.com",
    new_host_email:      "new-host@example.com",
    zones:               ["zone-other-building"],
  }.to_json

  publish("staff/booking/host_changed", host_changed_wrong_zone)
  sleep 0.5

  # Count should not have increased — event was for a different building
  system(:Mailer)[:send_count].should eq 5

  # ------------------------------------------------------------------
  # Test 9: booking_host_changed — nil zones skips zone filter
  # ------------------------------------------------------------------

  host_changed_no_zones = {
    action:              "host_changed",
    booking_id:          202_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_title:         "No Zone Meeting",
    event_summary:       "No Zone Meeting",
    event_starting:      now + 7200,
    previous_host_email: "old-host2@example.com",
    new_host_email:      "new-host2@example.com",
  }.to_json

  publish("staff/booking/host_changed", host_changed_no_zones)
  sleep 1.5

  # When zones are nil, zone filtering is skipped — email should be sent
  system(:Mailer)[:send_count].should eq 6
  system(:Mailer)[:last_to].should eq "old-host2@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  # ------------------------------------------------------------------
  # Test 10: booking_host_changed — event_title nil falls back to
  #          event_summary
  # ------------------------------------------------------------------

  host_changed_no_title = {
    action:              "host_changed",
    booking_id:          203_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_summary:       "Fallback Summary Title",
    event_starting:      now + 3600,
    previous_host_email: "old-host3@example.com",
    new_host_email:      "new-host3@example.com",
    zones:               ["zone-building"],
  }.to_json

  publish("staff/booking/host_changed", host_changed_no_title)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 7
  system(:Mailer)[:last_to].should eq "old-host3@example.com"

  args10 = system(:Mailer)[:last_args]
  # event_title is nil in the payload, so it falls back to event_summary
  args10["event_title"].should eq "Fallback Summary Title"

  # ------------------------------------------------------------------
  # Test 10b: booking_host_changed — both event_title and event_summary
  #           are null (booking has no title or description).  Must not
  #           crash during deserialisation.
  # ------------------------------------------------------------------

  host_changed_nil_summary = {
    action:              "host_changed",
    booking_id:          204_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_starting:      now + 3600,
    previous_host_email: "old-host4@example.com",
    new_host_email:      "new-host4@example.com",
    zones:               ["zone-building"],
  }.to_json

  publish("staff/booking/host_changed", host_changed_nil_summary)
  sleep 1.5

  # Email should still be sent — event_title falls back to nil gracefully
  system(:Mailer)[:send_count].should eq 8
  system(:Mailer)[:last_to].should eq "old-host4@example.com"

  args10b = system(:Mailer)[:last_args]
  args10b["event_title"].raw.should be_nil

  # ==================================================================
  # event_changed_event tests (staff/event/changed)
  # ==================================================================

  # ------------------------------------------------------------------
  # Test 11: event_changed with time change — sends booking_changed
  #          emails to all visitors on the event
  # ------------------------------------------------------------------

  event_changed_time = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-100",
    event_ical_uid:       "ical-100",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Quarterly Review",
    event_start:          now + 7200,
    event_end:            now + 10800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
  }.to_json

  publish("staff/event/changed", event_changed_time)
  sleep 1.5

  # Visitor should receive a booking_changed email
  system(:Mailer)[:send_count].should eq 9
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  args11 = system(:Mailer)[:last_args]
  args11["host_name"].should eq "Host User"
  args11["host_email"].should eq "host@example.com"
  args11["event_title"].should eq "Quarterly Review"
  args11["building_name"].should eq "Main Building"
  # previous dates should be present
  args11["previous_event_date"].should_not be_nil
  args11["previous_event_time"].should_not be_nil

  # ------------------------------------------------------------------
  # Test 12: event_changed with location change (system_id differs) —
  #          sends booking_changed emails to visitors
  # ------------------------------------------------------------------

  event_changed_location = {
    action:             "update",
    system_id:          "sys-room1",
    event_id:           "evt-101",
    event_ical_uid:     "ical-101",
    host:               "host@example.com",
    resource:           "room1@example.com",
    title:              "Sprint Planning",
    event_start:        now + 3600,
    event_end:          now + 7200,
    zones:              ["zone-building", "zone-room"],
    previous_system_id: "sys-old-room",
  }.to_json

  publish("staff/event/changed", event_changed_location)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 10
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  args12 = system(:Mailer)[:last_args]
  args12["event_title"].should eq "Sprint Planning"

  # ------------------------------------------------------------------
  # Test 13: event_changed with host change — sends host-change
  #          notification to the previous host
  # ------------------------------------------------------------------

  event_changed_host = {
    action:              "update",
    system_id:           "sys-room1",
    event_id:            "evt-102",
    event_ical_uid:      "ical-102",
    host:                "new-organiser@example.com",
    resource:            "room1@example.com",
    title:               "Design Review",
    event_start:         now + 3600,
    event_end:           now + 7200,
    zones:               ["zone-building"],
    previous_host_email: "old-organiser@example.com",
  }.to_json

  publish("staff/event/changed", event_changed_host)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 11
  system(:Mailer)[:last_to].should eq "old-organiser@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  args13 = system(:Mailer)[:last_args]
  args13["previous_host_email"].should eq "old-organiser@example.com"
  args13["new_host_email"].should eq "new-organiser@example.com"
  args13["event_title"].should eq "Design Review"

  # ------------------------------------------------------------------
  # Test 14: event_changed — action "create" is ignored (no previous
  #          values to compare)
  # ------------------------------------------------------------------

  event_created_payload = {
    action:         "create",
    system_id:      "sys-room1",
    event_id:       "evt-103",
    event_ical_uid: "ical-103",
    host:           "host@example.com",
    resource:       "room1@example.com",
    title:          "New Meeting",
    event_start:    now + 3600,
    event_end:      now + 7200,
    zones:          ["zone-building"],
  }.to_json

  publish("staff/event/changed", event_created_payload)
  sleep 0.5

  # No email — create events have no previous state to diff against
  system(:Mailer)[:send_count].should eq 11

  # ------------------------------------------------------------------
  # Test 15: event_changed — wrong zone is ignored
  # ------------------------------------------------------------------

  event_changed_wrong_zone = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-104",
    event_ical_uid:       "ical-104",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Offsite Meeting",
    event_start:          now + 7200,
    event_end:            now + 10800,
    zones:                ["zone-other-building"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
  }.to_json

  publish("staff/event/changed", event_changed_wrong_zone)
  sleep 0.5

  system(:Mailer)[:send_count].should eq 11

  # ------------------------------------------------------------------
  # Test 16: event_changed — no actual changes (previous == current)
  #          does not send email
  # ------------------------------------------------------------------

  event_changed_no_diff = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-105",
    event_ical_uid:       "ical-105",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Unchanged Meeting",
    event_start:          now + 3600,
    event_end:            now + 7200,
    zones:                ["zone-building"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
  }.to_json

  publish("staff/event/changed", event_changed_no_diff)
  sleep 0.5

  system(:Mailer)[:send_count].should eq 11
end
