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

  # Reset counters before publishing
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
end
