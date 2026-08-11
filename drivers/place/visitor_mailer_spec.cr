require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  # Every template name sent so far, so a test can assert which emails an event
  # produced rather than only counting them.
  @templates_sent : Array(String) = [] of String

  # "recipient|template" for each email, so a test can assert exactly who
  # received which one rather than only counting.
  @emails_sent : Array(String) = [] of String

  def on_load
    self[:send_count] = 0
    self[:sent_templates] = @templates_sent
    self[:emails_sent] = @emails_sent
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
    self[:last_reply_to] = reply_to
    self[:last_attachments] = resource_attachments
    @templates_sent << template[1]
    self[:sent_templates] = @templates_sent
    @emails_sent << "#{to.is_a?(Array) ? to.join(',') : to}|#{template[1]}"
    self[:emails_sent] = @emails_sent
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

  # Used by send_visitor_qr_email when @disable_qr_code is false (the default).
  def generate_png_qrcode(text : String, size : Int32 = 256)
    "PNG-#{text}-#{size}"
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

  # When include_linked is true, parent group bookings (e.g. id 300) return
  # guests from all child bookings in a single response — just like the real
  # staff-api endpoint.
  def booking_guests(booking_id : Int64, include_linked : Bool? = nil)
    case booking_id
    when 300
      if include_linked
        [
          {email: "visitor-a@external.com", name: "Visitor A", checked_in: false, visit_expected: true},
          {email: "visitor-b@external.com", name: "Visitor B", checked_in: false, visit_expected: true},
        ]
      else
        [] of NamedTuple(email: String, name: String, checked_in: Bool, visit_expected: Bool)
      end
    when 301
      # Simulates the host being stored as a visit_expected attendee
      # alongside a real external visitor (mirrors what events.cr does
      # when it appends the host with visit_expected: true).
      [
        {email: "host@example.com", name: "Host User", checked_in: false, visit_expected: true},
        {email: "visitor@external.com", name: "Visitor One", checked_in: false, visit_expected: true},
      ]
    when 302
      # A colleague of the host (same domain) alongside a real visitor — the
      # front-end marks every attendee as an expected visitor.
      [
        {email: "colleague@example.com", name: "Colleague", checked_in: false, visit_expected: true},
        {email: "visitor@external.com", name: "Visitor One", checked_in: false, visit_expected: true},
      ]
    else
      [{email: "visitor@external.com", name: "Visitor One", checked_in: false, visit_expected: true}]
    end
  end

  def event_guests(event_id : String, system_id : String, ical_uid : String? = nil)
    case event_id
    when "evt-two-visitors"
      # An existing visitor plus one added by the same edit.
      [
        {email: "visitor-a@external.com", name: "Visitor A", checked_in: false, visit_expected: true},
        {email: "visitor-b@external.com", name: "Visitor B", checked_in: false, visit_expected: true},
      ]
    when "evt-host-in-guests"
      # Mirrors the production scenario where events.cr stores the host
      # as an attendee (visit_expected: true), so they appear in the
      # event guest list alongside real visitors.
      [
        {email: "host@example.com", name: "Host User", checked_in: false, visit_expected: true},
        {email: "visitor@external.com", name: "Visitor One", checked_in: false, visit_expected: true},
      ]
    else
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

  def get_system(id : String, complete : Bool = false)
    case id
    when "sys-room1"
      {id: "sys-room1", name: "Room 1", display_name: "Conference Room 1", map_id: nil, zones: ["zone-building", "zone-room"]}
    when "sys-room2"
      # second room in the SAME building, so signals for it pass the zone filter
      {id: "sys-room2", name: "Room 2", display_name: "Conference Room 2", map_id: nil, zones: ["zone-building", "zone-room2"]}
    when "sys-old-room"
      {id: "sys-old-room", name: "Room 202", display_name: "Old Conference Room 202", map_id: nil, zones: ["zone-old-building", "zone-old-room"]}
    when "sys-error"
      raise "system not found: #{id}"
    else
      {id: id, name: "Unknown Room", display_name: nil, map_id: nil, zones: [] of String}
    end
  end

  # 600 — standalone visitor booking
  # 601 — event-linked visitor booking (parent_id set)
  # 602 — group-event booking
  # Group visitors get their own booking beneath a group parent, which is how the
  # driver tells "added to the group by this edit" from "this is the visit".
  #   305/306/307 — children of group parent 300
  #   600         — child of group parent 599
  #   801         — child of group container 800
  GROUP_CHILDREN = {
    305_i64 => 300_i64,
    306_i64 => 300_i64,
    307_i64 => 300_i64,
    600_i64 => 599_i64,
    801_i64 => 800_i64,
  }

  def get_booking(booking_id : Int64, instance : Int64? = nil)
    if parent = GROUP_CHILDREN[booking_id]?
      return {
        id:             booking_id,
        parent_id:      parent,
        booking_type:   "visitor",
        booking_start:  0,
        booking_end:    0,
        resource_id:    "visitor@external.com",
        user_email:     "host@example.com",
        title:          "Group Member Visit",
        extension_data: {} of String => String,
      }
    end

    case booking_id
    when 601_i64
      {
        id:             601,
        booking_type:   "visitor",
        booking_start:  0,
        booking_end:    0,
        resource_id:    "visitor@external.com",
        user_email:     "host@example.com",
        title:          "Linked Visit",
        extension_data: {parent_id: "event-evt-200"},
      }
    when 602_i64
      {
        id:             602,
        booking_type:   "group-event",
        booking_start:  0,
        booking_end:    0,
        resource_id:    "visitor@external.com",
        user_email:     "host@example.com",
        title:          "Group Event Visit",
        extension_data: {} of String => String,
      }
    else
      {
        id:             booking_id,
        booking_type:   "visitor",
        booking_start:  0,
        booking_end:    0,
        resource_id:    "visitor@external.com",
        user_email:     "host@example.com",
        title:          "Standalone Visit",
        extension_data: {} of String => String,
      }
    end
  end

  # Back-fills event_start when a staff/event/changed signal omits it.
  # event_start/event_end are epoch integers, matching the real
  # PlaceCalendar::Event serialisation (Time::EpochConverter).
  def get_event(event_id : String, system_id : String? = nil, calendar : String? = nil)
    case event_id
    when "evt-no-start"
      # Simulates an event the API can't supply a start time for.
      {id: event_id, title: "No Start Event"}
    else
      {id: event_id, title: "Looked Up Event", event_start: 1_760_000_000_i64, event_end: 1_760_003_600_i64}
    end
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

  # Most tests below assert an immediate send, so the debounce is disabled (it
  # defaults to 15s). The debounce behaviour has dedicated tests that turn it
  # back on. send_reminders/domain_uri mirror default_settings so nothing else
  # changes.
  settings({
    change_debounce: 0,
    send_reminders:  "0 7 * * *",
    domain_uri:      "https://example.com/",
  })
  sleep 1.0

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
  # replies from the visitor should reach the host
  system(:Mailer)[:last_reply_to].should eq "host@example.com"

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

  # ------------------------------------------------------------------
  # Test 6c: booking_changed with end-time-only change.
  #          Start time and zones are the same, only the end time moved
  #          earlier (e.g. 5pm → 3pm).  Visitors should still be notified.
  # ------------------------------------------------------------------

  changed_payload_end_only = {
    action:                 "metadata_changed",
    id:                     107_i64,
    booking_type:           "desk",
    booking_start:          now + 3600,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "End Time Only Change",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 14400,
  }.to_json

  publish("staff/booking/changed", changed_payload_end_only)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 5
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]
  system(:Mailer)[:last_args]["event_title"].should eq "End Time Only Change"

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
  system(:Mailer)[:send_count].should eq 6
  system(:Mailer)[:last_to].should eq "old-host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]
  # the previous host's replies should reach the new host
  system(:Mailer)[:last_reply_to].should eq "new-host@example.com"

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
  system(:Mailer)[:send_count].should eq 6

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
  system(:Mailer)[:send_count].should eq 7
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

  system(:Mailer)[:send_count].should eq 8
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
  system(:Mailer)[:send_count].should eq 9
  system(:Mailer)[:last_to].should eq "old-host4@example.com"

  args10b = system(:Mailer)[:last_args]
  args10b["event_title"].raw.should be_nil

  # ==================================================================
  # event_changed_event tests (staff/event/changed)
  # ==================================================================

  # These tests assert an immediate send, so disable the debounce (default 15s).
  # send_reminders/domain_uri mirror default_settings so nothing else changes.
  settings({
    change_debounce: 0,
    send_reminders:  "0 7 * * *",
    domain_uri:      "https://example.com/",
  })
  sleep 1.0

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
  system(:Mailer)[:send_count].should eq 10
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  args11 = system(:Mailer)[:last_args]
  args11["host_name"].should eq "Host User"
  args11["host_email"].should eq "host@example.com"
  args11["event_title"].should eq "Quarterly Review"
  args11["building_name"].should eq "Main Building"
  # previous dates should be present
  args11["previous_event_date"].should_not be_nil
  args11["previous_event_time"].should_not be_nil
  # The location did NOT change, so the "previous" room/building must mirror
  # the (unchanged) current room — resolved from system_id — rather than the
  # static @booking_space_name fallback.  Otherwise the email shows a bogus
  # "moved from" room for a date/time-only edit.
  args11["room_name"].should eq "Conference Room 1"
  args11["building_name"].should eq "Main Building"
  args11["previous_room_name"].should eq "Conference Room 1"
  args11["previous_building_name"].should eq "Main Building"

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

  system(:Mailer)[:send_count].should eq 11
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

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

  system(:Mailer)[:send_count].should eq 12
  system(:Mailer)[:last_to].should eq "old-organiser@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  args13 = system(:Mailer)[:last_args]
  args13["previous_host_email"].should eq "old-organiser@example.com"
  args13["new_host_email"].should eq "new-organiser@example.com"
  args13["event_title"].should eq "Design Review"

  # ------------------------------------------------------------------
  # Test 13b: event_changed host change where the payload omits
  #           event_end (a metadata-only reassignment).  The previous
  #           host must STILL be notified — the host-change notification
  #           does not depend on the event end time.
  # ------------------------------------------------------------------

  count_before_host_no_end = system(:Mailer)[:send_count].as_i

  event_changed_host_no_end = {
    action:         "update",
    system_id:      "sys-room1",
    event_id:       "evt-110",
    event_ical_uid: "ical-110",
    host:           "new-organiser2@example.com",
    resource:       "room1@example.com",
    title:          "Reassigned No End",
    event_start:    now + 3600,
    # no event_end
    zones:               ["zone-building"],
    previous_host_email: "old-organiser2@example.com",
  }.to_json

  publish("staff/event/changed", event_changed_host_no_end)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_host_no_end + 1
  system(:Mailer)[:last_to].should eq "old-organiser2@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  args13b = system(:Mailer)[:last_args]
  args13b["previous_host_email"].should eq "old-organiser2@example.com"
  args13b["new_host_email"].should eq "new-organiser2@example.com"
  args13b["event_title"].should eq "Reassigned No End"
  # event_start was present, so the date should still render
  args13b["event_date"].raw.should_not be_nil

  # ------------------------------------------------------------------
  # Test 13c: event_changed host change where the payload omits BOTH
  #           event_start and event_end (pure metadata reassignment).
  #           The previous host must still be notified; the date/time
  #           fields are simply left blank.
  # ------------------------------------------------------------------

  count_before_host_no_times = system(:Mailer)[:send_count].as_i

  event_changed_host_no_times = {
    action:         "update",
    system_id:      "sys-room1",
    event_id:       "evt-111",
    event_ical_uid: "ical-111",
    host:           "new-organiser3@example.com",
    resource:       "room1@example.com",
    title:          "Reassigned No Times",
    # no event_start, no event_end
    zones:               ["zone-building"],
    previous_host_email: "old-organiser3@example.com",
  }.to_json

  publish("staff/event/changed", event_changed_host_no_times)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_host_no_times + 1
  system(:Mailer)[:last_to].should eq "old-organiser3@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

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
  system(:Mailer)[:send_count].should eq 14

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

  system(:Mailer)[:send_count].should eq 14

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

  system(:Mailer)[:send_count].should eq 14

  # ------------------------------------------------------------------
  # Test 17: event_changed with end-time-only change.
  #          Start time and system_id are the same, only the end time
  #          moved earlier.  Visitors should still be notified.
  # ------------------------------------------------------------------

  event_changed_end_only = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-106",
    event_ical_uid:       "ical-106",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "End Time Only Event",
    event_start:          now + 3600,
    event_end:            now + 7200,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 10800,
  }.to_json

  publish("staff/event/changed", event_changed_end_only)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 15
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]
  system(:Mailer)[:last_args]["event_title"].should eq "End Time Only Event"

  # ------------------------------------------------------------------
  # Test 18: event_changed with location change — previous_room_name and
  #          previous_building_name show the PREVIOUS location, not the
  #          current one. previous_system_id differs from system_id.
  # ------------------------------------------------------------------

  event_changed_prev_location = {
    action:             "update",
    system_id:          "sys-room1",
    event_id:           "evt-108",
    event_ical_uid:     "ical-108",
    host:               "host@example.com",
    resource:           "room1@example.com",
    title:              "Location Change Meeting",
    event_start:        now + 3600,
    event_end:          now + 7200,
    zones:              ["zone-building", "zone-room"],
    previous_system_id: "sys-old-room",
  }.to_json

  publish("staff/event/changed", event_changed_prev_location)
  sleep 1.5

  system(:Mailer)[:send_count].should eq 16
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  args18 = system(:Mailer)[:last_args]
  args18["event_title"].should eq "Location Change Meeting"
  # previous location should come from the previous system (sys-old-room), NOT the current
  args18["previous_room_name"].should eq "Old Conference Room 202"
  args18["previous_building_name"].should eq "Previous Building"
  # current location should be resolved from the signal's system_id (sys-room1)
  # rather than the static @booking_space_name setting, so visitors can see
  # which room the meeting moved to.
  args18["room_name"].should eq "Conference Room 1"
  args18["building_name"].should eq "Main Building"

  # ------------------------------------------------------------------
  # Test 18b: event_changed with an unresolvable previous_system_id.
  #           get_room_details retries 4× with 1-second delays before
  #           giving up, so previous_room_name must fall back to "unknown"
  #           rather than silently showing the current room.
  # Note: this test requires a longer sleep to accommodate the retries.
  # ------------------------------------------------------------------

  event_changed_error_system = {
    action:             "update",
    system_id:          "sys-room1",
    event_id:           "evt-109",
    event_ical_uid:     "ical-109",
    host:               "host@example.com",
    resource:           "room1@example.com",
    title:              "Error System Meeting",
    event_start:        now + 3600,
    event_end:          now + 7200,
    zones:              ["zone-building", "zone-room"],
    previous_system_id: "sys-error",
  }.to_json

  count_before_18b = system(:Mailer)[:send_count].as_i
  publish("staff/event/changed", event_changed_error_system)
  sleep 6.0 # allow for 4× 1-second retries inside get_room_details

  system(:Mailer)[:send_count].should eq count_before_18b + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  args18b = system(:Mailer)[:last_args]
  args18b["event_title"].should eq "Error System Meeting"
  args18b["previous_room_name"].should eq "unknown"

  # ------------------------------------------------------------------
  # Test 19: booking_changed with action "approved" that contains
  #          previous_* field differences must NOT send an email.
  #          Only "changed" and "metadata_changed" actions are relevant.
  # ------------------------------------------------------------------

  approved_payload_with_diff = {
    action:                 "approved",
    id:                     108_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Approved Booking",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  count_before_approved = system(:Mailer)[:send_count].as_i
  publish("staff/booking/changed", approved_payload_with_diff)
  sleep 0.5

  # "approved" is not a visitor-notification action — no email should be sent
  system(:Mailer)[:send_count].should eq count_before_approved

  # ==================================================================
  # Group booking linked-guest tests
  # ==================================================================

  # ------------------------------------------------------------------
  # Test 20: booking_changed for a parent "group" booking.  The driver
  #          passes include_linked: true so the API aggregates guests
  #          from child bookings into a single response.  The mock
  #          returns 2 unique guests for booking 300 when the flag is
  #          set, simulating this aggregation.
  # ------------------------------------------------------------------

  count_before_group = system(:Mailer)[:send_count].as_i

  group_changed_payload = {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "host@example.com[2026-05-15]",
    resource_ids:           ["host@example.com[2026-05-15]"],
    user_email:             "host@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  publish("staff/booking/changed", group_changed_payload)
  sleep 1.5

  # The mock returns 2 unique guests for booking 300 with
  # include_linked: true, so 2 emails should be sent.
  system(:Mailer)[:send_count].should eq count_before_group + 2

  # Last email should be to visitor-b (second child processed)
  system(:Mailer)[:last_to].should eq "visitor-b@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  args20 = system(:Mailer)[:last_args]
  args20["event_title"].should eq "Group Visit"
  args20["host_email"].should eq "host@example.com"

  # ------------------------------------------------------------------
  # Test 21: non-group booking should NOT pass include_linked.  The
  #          mock for booking 300 returns an empty guest list when
  #          include_linked is false, so if the driver incorrectly
  #          passes include_linked: true for a non-group type the
  #          assertion below would fail (2 emails would be sent).
  # ------------------------------------------------------------------

  count_before_non_group = system(:Mailer)[:send_count].as_i

  non_group_payload = {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Desk Booking",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  publish("staff/booking/changed", non_group_payload)
  sleep 0.5

  # Booking 300 with include_linked: false returns no guests, so no
  # emails should be sent.  This proves the driver does not pass
  # include_linked: true for non-group booking types.
  system(:Mailer)[:send_count].should eq count_before_non_group

  # Test 22: event-linked booking_created is skipped by default

  count_before_linked = system(:Mailer)[:send_count].as_i

  linked_booking_created_payload = {
    action:         "booking_created",
    booking_id:     601_i64,
    resource_id:    "visitor@external.com",
    event_title:    "Linked Visit",
    event_summary:  "Linked Visit",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/attending", linked_booking_created_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_linked

  # Test 23: standalone booking_created still emits the booking template

  count_before_standalone = system(:Mailer)[:send_count].as_i

  standalone_booking_created_payload = {
    action:         "booking_created",
    booking_id:     600_i64,
    resource_id:    "visitor@external.com",
    event_title:    "Standalone Visit",
    event_summary:  "Standalone Visit",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/attending", standalone_booking_created_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_standalone + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking"]
  system(:Mailer)[:last_to].should eq "visitor@external.com"

  # Test 24: opt-out restores the legacy dual-email behaviour

  settings({
    timezone:                        "GMT",
    booking_space_name:              "Client Floor",
    invite_zone_tag:                 "building",
    skip_event_linked_booking_email: false,
    change_debounce:                 0,
  })
  sleep 1.0

  count_before_opt_out = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", linked_booking_created_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_opt_out + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking"]
  system(:Mailer)[:last_to].should eq "visitor@external.com"

  # ==================================================================
  # skip_host_email tests (PPT-2375)
  # ==================================================================
  #
  # When events.cr / bookings.cr add the host as an attendee with
  # visit_expected: true, the host ends up in the guest list and would
  # otherwise receive their own visitor / check-in / booking_changed
  # emails.  The skip_host_email setting (default true) filters them out
  # in the driver — Office 365 mail is out of scope.

  # ------------------------------------------------------------------
  # Test 25: guest_event — host listed as attendee on a booking is
  #          NOT sent the visitor invite (skip_host_email default true)
  # ------------------------------------------------------------------

  count_before_host_attendee = system(:Mailer)[:send_count].as_i

  host_as_attendee_payload = {
    action:         "booking_created",
    booking_id:     700_i64,
    resource_id:    "host@example.com",
    event_title:    "Self-Invited Booking",
    event_summary:  "Self-Invited Booking",
    event_starting: now + 3600,
    attendee_name:  "Host User",
    attendee_email: "host@example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/attending", host_as_attendee_payload)
  sleep 0.5

  # Default skip_host_email: true means no email is sent to the host
  system(:Mailer)[:send_count].should eq count_before_host_attendee

  # ------------------------------------------------------------------
  # Test 26: guest_event — host check is case-insensitive
  # ------------------------------------------------------------------

  count_before_case = system(:Mailer)[:send_count].as_i

  host_case_payload = {
    action:         "booking_created",
    booking_id:     701_i64,
    resource_id:    "host@example.com",
    event_title:    "Case Booking",
    event_summary:  "Case Booking",
    event_starting: now + 3600,
    attendee_name:  "Host User",
    attendee_email: "Host@Example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/attending", host_case_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_case

  # ------------------------------------------------------------------
  # Test 27: guest_event — real visitor still receives invite when host
  #          is filtered (sanity check that the host filter doesn't
  #          over-match)
  # ------------------------------------------------------------------

  count_before_visitor = system(:Mailer)[:send_count].as_i

  visitor_only_payload = {
    action:         "booking_created",
    booking_id:     702_i64,
    resource_id:    "visitor@external.com",
    event_title:    "Real Visitor Booking",
    event_summary:  "Real Visitor Booking",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/attending", visitor_only_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_visitor + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking"]

  # ------------------------------------------------------------------
  # Test 28: send_booking_changed_emails (via event_changed_event) —
  #          host present in event_guests is NOT sent the
  #          booking_changed email, but real visitors still are.
  # ------------------------------------------------------------------

  count_before_evt_host = system(:Mailer)[:send_count].as_i

  event_changed_host_in_guests = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-host-in-guests",
    event_ical_uid:       "ical-host-in-guests",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Mixed Guests Meeting",
    event_start:          now + 7200,
    event_end:            now + 10800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
  }.to_json

  publish("staff/event/changed", event_changed_host_in_guests)
  sleep 1.5

  # event_guests mock returns BOTH host and visitor for evt-host-in-guests,
  # but only the visitor should receive the booking_changed email.
  system(:Mailer)[:send_count].should eq count_before_evt_host + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  # ------------------------------------------------------------------
  # Test 29: send_booking_changed_emails (via booking_changed_event) —
  #          same filtering applies when the booking_guests response
  #          contains the host.
  # ------------------------------------------------------------------

  count_before_bk_host = system(:Mailer)[:send_count].as_i

  booking_changed_host_in_guests = {
    action:                 "changed",
    id:                     301_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Mixed Guests Booking",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  publish("staff/booking/changed", booking_changed_host_in_guests)
  sleep 1.5

  # booking_guests mock for id 301 returns BOTH host and visitor,
  # but only the visitor should receive the booking_changed email.
  system(:Mailer)[:send_count].should eq count_before_bk_host + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # ------------------------------------------------------------------
  # Test 30: notify_original_host email is unaffected by
  #          skip_host_email — sending an email to the previous host
  #          is the entire point of that template, even though the
  #          recipient happens to be a host.
  # ------------------------------------------------------------------

  count_before_prev_host = system(:Mailer)[:send_count].as_i

  prev_host_payload = {
    action:              "host_changed",
    booking_id:          702_i64,
    resource_id:         "desk-1",
    resource_ids:        ["desk-1"],
    event_title:         "Reassigned Booking",
    event_summary:       "Reassigned Booking",
    event_starting:      now + 3600,
    previous_host_email: "prev-host@example.com",
    new_host_email:      "new-host@example.com",
    zones:               ["zone-building", "zone-room"],
  }.to_json

  publish("staff/booking/host_changed", prev_host_payload)
  sleep 1.5

  # Previous-host notification still fires regardless of skip_host_email
  system(:Mailer)[:send_count].should eq count_before_prev_host + 1
  system(:Mailer)[:last_to].should eq "prev-host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  # ------------------------------------------------------------------
  # Test 31: opt-out (skip_host_email: false) restores legacy behaviour
  #          — the host receives the visitor invite when listed as an
  #          attendee.
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    skip_host_email:    false,
    change_debounce:    0,
  })
  sleep 1.0

  count_before_optout = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", host_as_attendee_payload)
  sleep 0.5

  system(:Mailer)[:send_count].should eq count_before_optout + 1
  system(:Mailer)[:last_to].should eq "host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking"]

  # And the host now also receives booking_changed emails when present
  # in the guest list
  count_before_optout_bc = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", event_changed_host_in_guests)
  sleep 1.5

  # Both host AND visitor receive the booking_changed email
  system(:Mailer)[:send_count].should eq count_before_optout_bc + 2

  # ------------------------------------------------------------------
  # Test 32: induction template settings (PPT-2375 bug fix)
  #          Verify that custom `notify_induction_accepted_template` and
  #          `notify_induction_declined_template` settings are actually
  #          picked up.  Previously on_update read the wrong setting keys
  #          (:induction_accepted / :induction_declined) so any override
  #          silently fell back to the defaults.
  # ------------------------------------------------------------------

  settings({
    timezone:                           "GMT",
    booking_space_name:                 "Client Floor",
    invite_zone_tag:                    "building",
    notify_induction_accepted_template: "custom_accepted",
    notify_induction_declined_template: "custom_declined",
    change_debounce:                    0,
  })
  sleep 1.0

  count_before_induction_accept = system(:Mailer)[:send_count].as_i

  induction_accepted_payload = {
    action:         "induction_accepted",
    induction:      "ACCEPTED",
    booking_id:     800_i64,
    resource_id:    "desk-1",
    resource_ids:   ["desk-1"],
    event_title:    "Induction Booking",
    event_summary:  "Induction Booking",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/induction_accepted", induction_accepted_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_induction_accept + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "custom_accepted"]

  count_before_induction_decline = system(:Mailer)[:send_count].as_i

  induction_declined_payload = {
    action:         "induction_declined",
    induction:      "DECLINED",
    booking_id:     801_i64,
    resource_id:    "desk-1",
    resource_ids:   ["desk-1"],
    event_title:    "Induction Booking",
    event_summary:  "Induction Booking",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/induction_declined", induction_declined_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_induction_decline + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "custom_declined"]

  # ------------------------------------------------------------------
  # Test 33: event (room) changes and booking changes use SEPARATE
  #          templates.  event_changed_event must use the
  #          `event_changed_template`, while booking_changed_event keeps
  #          the `booking_changed_template`.  Custom overrides confirm
  #          both setting keys are wired up correctly.
  # ------------------------------------------------------------------

  settings({
    timezone:                 "GMT",
    booking_space_name:       "Client Floor",
    invite_zone_tag:          "building",
    booking_changed_template: "custom_booking_changed",
    event_changed_template:   "custom_event_changed",
    change_debounce:          0,
  })
  sleep 1.0

  # --- event (room) based change uses the event_changed template
  count_before_split_event = system(:Mailer)[:send_count].as_i

  split_event_payload = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-split",
    event_ical_uid:       "ical-split",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Split Event Change",
    event_start:          now + 7200,
    event_end:            now + 10800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
  }.to_json

  publish("staff/event/changed", split_event_payload)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_split_event + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "custom_event_changed"]

  # --- booking based change still uses the booking_changed template
  count_before_split_booking = system(:Mailer)[:send_count].as_i

  split_booking_payload = {
    action:                 "changed",
    id:                     900_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Split Booking Change",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  publish("staff/booking/changed", split_booking_payload)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_split_booking + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "custom_booking_changed"]

  # ==================================================================
  # Issue 2 — event-linked booking changes must still notify (PPT-2375)
  # ==================================================================
  #
  # attendee_scanner creates visitor bookings for external calendar guests
  # with extension_data.parent_id pointing at the source event.  Editing
  # such a booking only emits staff/booking/changed — the linked calendar
  # event is untouched, so NO staff/event/changed fires to cover it.
  # An earlier de-duplication attempt skipped these bookings entirely, which
  # silently dropped the visitor's only change notification.  They must be
  # treated like any other booking change.

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    # skip_event_linked_booking_email defaults to true (invite flow only)
    change_debounce: 0,
  })
  sleep 1.0

  # ------------------------------------------------------------------
  # Test 34: booking_changed for an event-linked booking STILL notifies
  #          (regression: it was previously suppressed, losing the email)
  # ------------------------------------------------------------------

  count_before_linked_change = system(:Mailer)[:send_count].as_i

  linked_booking_changed = {
    action:                 "changed",
    id:                     601_i64,
    booking_type:           "visitor",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host@example.com",
    title:                  "Linked Visit Changed",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
    extension_data:         {parent_id: "event-evt-200"},
  }.to_json

  publish("staff/booking/changed", linked_booking_changed)
  sleep 1.5

  # The booking edit is the only signal these visitors receive, so it must
  # produce the booking_changed notification.
  system(:Mailer)[:send_count].should eq count_before_linked_change + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # ------------------------------------------------------------------
  # Test 35: standalone booking_changed (no parent_id) still notifies
  # ------------------------------------------------------------------

  count_before_standalone_change = system(:Mailer)[:send_count].as_i

  standalone_booking_changed = {
    action:                 "changed",
    id:                     600_i64,
    booking_type:           "visitor",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host@example.com",
    title:                  "Standalone Visit Changed",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
    # no extension_data / parent_id
  }.to_json

  publish("staff/booking/changed", standalone_booking_changed)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_standalone_change + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # ------------------------------------------------------------------
  # Test 36: skip_event_linked_booking_email governs only the invite
  #          (guest_event) flow — event-linked booking *changes* notify
  #          regardless of the setting value.
  # ------------------------------------------------------------------

  settings({
    timezone:                        "GMT",
    booking_space_name:              "Client Floor",
    invite_zone_tag:                 "building",
    skip_event_linked_booking_email: false,
    change_debounce:                 0,
  })
  sleep 1.0

  count_before_optout_linked = system(:Mailer)[:send_count].as_i

  publish("staff/booking/changed", linked_booking_changed)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_optout_linked + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # ==================================================================
  # event_start back-fill
  # ==================================================================
  #
  # Metadata-only staff/event/changed signals (e.g. update_metadata) omit
  # the top-level event_start.  The host-change notification must still
  # show a real date, so the driver looks the event up via the staff API.

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
  })
  sleep 1.0

  # ------------------------------------------------------------------
  # Test 37: event_start is looked up when omitted from the payload
  # ------------------------------------------------------------------

  count_before_lookup = system(:Mailer)[:send_count].as_i

  event_changed_needs_lookup = {
    action:         "update",
    system_id:      "sys-room1",
    event_id:       "evt-needs-lookup",
    event_ical_uid: "ical-needs-lookup",
    host:           "new-host-l@example.com",
    resource:       "room1@example.com",
    title:          "Needs Lookup",
    # no event_start / event_end (metadata-only update)
    zones:               ["zone-building"],
    previous_host_email: "old-host-l@example.com",
  }.to_json

  publish("staff/event/changed", event_changed_needs_lookup)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_lookup + 1
  system(:Mailer)[:last_to].should eq "old-host-l@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]

  args37 = system(:Mailer)[:last_args]
  # The payload carried no event_start, so a non-nil date proves it was
  # back-filled from staff_api.get_event (epoch 1_760_000_000).
  args37["event_date"].raw.should_not be_nil
  args37["event_time"].raw.should_not be_nil

  # ------------------------------------------------------------------
  # Test 38: lookup that can't resolve a start time still notifies the
  #          previous host (date/time simply left blank).
  # ------------------------------------------------------------------

  count_before_no_start = system(:Mailer)[:send_count].as_i

  event_changed_no_start = {
    action:              "update",
    system_id:           "sys-room1",
    event_id:            "evt-no-start",
    event_ical_uid:      "ical-no-start",
    host:                "new-host-n@example.com",
    resource:            "room1@example.com",
    title:               "No Start",
    zones:               ["zone-building"],
    previous_host_email: "old-host-n@example.com",
  }.to_json

  publish("staff/event/changed", event_changed_no_start)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_no_start + 1
  system(:Mailer)[:last_to].should eq "old-host-n@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_original_host"]
  system(:Mailer)[:last_args]["event_date"].raw.should be_nil

  # ==================================================================
  # change_debounce — coalesce the Office365 signal burst (PPT-2375)
  # ==================================================================
  #
  # One edit arrives as an A -> B -> A flip-flop (Wed->Thu, Thu->Wed, Wed->Thu)
  # of staff/event/changed signals; the debounce must collapse it into ONE email
  # showing the true net change.

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    3,
  })
  sleep 1.0

  gmt = Time::Location.load("GMT")
  wed_start = now + 100_000
  thu_start = wed_start + 86_400 # exactly one day later

  # Wed -> Thu (organizer copy)
  debounce_signal_a1 = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-debounce",
    event_ical_uid:       "ical-debounce",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Temporal Uncertainty Forecasts",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json

  # Thu -> Wed (stale room-mailbox echo — the reversed signal)
  debounce_signal_b = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-debounce",
    event_ical_uid:       "ical-debounce",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Temporal Uncertainty Forecasts",
    event_start:          wed_start,
    event_end:            wed_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: thu_start,
    previous_event_end:   thu_start + 1800,
  }.to_json

  # Wed -> Thu (room copy catches up — settled state)
  debounce_signal_a2 = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-debounce",
    event_ical_uid:       "ical-debounce",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Temporal Uncertainty Forecasts",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json

  count_before_debounce = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", debounce_signal_a1)
  publish("staff/event/changed", debounce_signal_b)
  publish("staff/event/changed", debounce_signal_a2)

  # Still inside the 3s window: nothing should have been sent yet.
  sleep 1.0
  system(:Mailer)[:send_count].should eq count_before_debounce

  # After the window closes the burst collapses into a single email.
  # Allow the debounce plus one sweep interval.
  sleep 6.0
  system(:Mailer)[:send_count].should eq count_before_debounce + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  # The one email must show the true net change (Wed -> Thu), not the reversed echo.
  debounce_args = system(:Mailer)[:last_args]
  debounce_args["event_date"].should eq Time.unix(thu_start).in(gmt).to_s("%A, %-d %B")
  debounce_args["previous_event_date"].should eq Time.unix(wed_start).in(gmt).to_s("%A, %-d %B")

  # ------------------------------------------------------------------
  # Test 38b: a settings update mid-window neither drops the buffered
  #           change nor emails it early — the new sweep picks it up.
  # ------------------------------------------------------------------

  survives_signal = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-survives-update",
    event_ical_uid:       "ical-survives-update",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Settings Update",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json

  count_before_survives = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", survives_signal)
  sleep 1.0
  system(:Mailer)[:send_count].should eq count_before_survives

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    3,
  })

  # the update must not cut the window short
  sleep 0.5
  system(:Mailer)[:send_count].should eq count_before_survives

  sleep 6.0
  system(:Mailer)[:send_count].should eq count_before_survives + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  survives_args = system(:Mailer)[:last_args]
  survives_args["event_date"].should eq Time.unix(thu_start).in(gmt).to_s("%A, %-d %B")
  survives_args["previous_event_date"].should eq Time.unix(wed_start).in(gmt).to_s("%A, %-d %B")

  # ------------------------------------------------------------------
  # Test 38d: the burst is keyed on the ical uid, so two signals for the
  #           same event instance coalesce even when they report different
  #           event ids (mailbox copies / duplicate metadata rows).
  # ------------------------------------------------------------------

  count_before_ical = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-copy-a",
    event_ical_uid:       "ical-shared",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Shared Ical",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json)

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-copy-b",
    event_ical_uid:       "ical-shared",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Shared Ical",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json)

  sleep 1.0
  system(:Mailer)[:send_count].should eq count_before_ical

  sleep 6.0
  system(:Mailer)[:send_count].should eq count_before_ical + 1
  system(:Mailer)[:last_args]["event_title"].should eq "Shared Ical"

  # ------------------------------------------------------------------
  # Test 38e: a room move paired with a time change. The old room's
  #           mailbox echoes the time change against itself; merged with
  #           the move it must not steal the room back. Move signal first.
  # ------------------------------------------------------------------

  count_before_move = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-move-new",
    event_ical_uid:       "ical-move",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Moved And Rescheduled",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
    previous_system_id:   "sys-room2",
  }.to_json)

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room2",
    event_id:             "evt-move-old",
    event_ical_uid:       "ical-move",
    host:                 "host@example.com",
    resource:             "room2@example.com",
    title:                "Moved And Rescheduled",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room2"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
    previous_system_id:   "sys-room2",
  }.to_json)

  sleep 7.0
  system(:Mailer)[:send_count].should eq count_before_move + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"

  move_args = system(:Mailer)[:last_args]
  move_args["room_name"].should eq "Conference Room 1"
  move_args["previous_room_name"].should eq "Conference Room 2"
  move_args["event_date"].should eq Time.unix(thu_start).in(gmt).to_s("%A, %-d %B")
  move_args["previous_event_date"].should eq Time.unix(wed_start).in(gmt).to_s("%A, %-d %B")

  # ------------------------------------------------------------------
  # Test 38f: the same pair in the other order — echo first, then the
  #           move — must produce the identical email.
  # ------------------------------------------------------------------

  count_before_move_echo = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room2",
    event_id:             "evt-move2-old",
    event_ical_uid:       "ical-move-2",
    host:                 "host@example.com",
    resource:             "room2@example.com",
    title:                "Echo First",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room2"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
    previous_system_id:   "sys-room2",
  }.to_json)

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-move2-new",
    event_ical_uid:       "ical-move-2",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Echo First",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
    previous_system_id:   "sys-room2",
  }.to_json)

  sleep 7.0
  system(:Mailer)[:send_count].should eq count_before_move_echo + 1

  move_echo_args = system(:Mailer)[:last_args]
  move_echo_args["room_name"].should eq "Conference Room 1"
  move_echo_args["previous_room_name"].should eq "Conference Room 2"

  # ------------------------------------------------------------------
  # Test 38g: turning the debounce off flushes whatever is buffered, as no
  #           sweep will run to pick it up. Same flush as on_unload, which
  #           the spec harness cannot invoke directly.
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    30,
  })
  sleep 1.0

  drain_signal = {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-drain",
    event_ical_uid:       "ical-drain",
    host:                 "host@example.com",
    resource:             "room1@example.com",
    title:                "Unload Drain",
    event_start:          thu_start,
    event_end:            thu_start + 1800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: wed_start,
    previous_event_end:   wed_start + 1800,
  }.to_json

  count_before_drain = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", drain_signal)

  # Well inside the 30s window: the change is buffered, nothing sent yet.
  sleep 1.0
  system(:Mailer)[:send_count].should eq count_before_drain

  # Disabling the debounce flushes the buffer instead of orphaning it.
  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
  })
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_drain + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  drain_args = system(:Mailer)[:last_args]
  drain_args["event_date"].should eq Time.unix(thu_start).in(gmt).to_s("%A, %-d %B")
  drain_args["previous_event_date"].should eq Time.unix(wed_start).in(gmt).to_s("%A, %-d %B")

  # ==================================================================
  # visitor check-in tests (PPT-2535)
  # ==================================================================

  # ------------------------------------------------------------------
  # Test 39: guest_event — visitor check-in sends the notify_checkin
  #          email to the host. Payloads mirror what staff-api emits
  #          from bookings.cr#guest_checkin and events.cr#guest_checkin.
  # ------------------------------------------------------------------

  count_before_checkin = system(:Mailer)[:send_count].as_i
  checked_in_before = status[:users_checked_in]?.try(&.as_i64) || 0_i64

  booking_checkin_payload = {
    action:         "checkin",
    id:             900_i64,
    checkin:        true,
    booking_id:     900_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Catch Up",
    event_summary:  "Catch Up",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/checkin", booking_checkin_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_checkin + 1
  system(:Mailer)[:last_to].should eq "host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_checkin"]
  status[:users_checked_in].should eq checked_in_before + 1

  args_checkin = system(:Mailer)[:last_args]
  args_checkin["visitor_email"].should eq "visitor@external.com"
  args_checkin["host_email"].should eq "host@example.com"
  args_checkin["event_title"].should eq "Catch Up"

  event_checkin_payload = {
    action:         "checkin",
    id:             901_i64,
    checkin:        true,
    system_id:      "sys-room1",
    event_id:       "evt-900",
    event_ical_uid: "ical-900",
    host:           "host@example.com",
    resource:       "room1@example.com",
    event_title:    "Catch Up",
    event_summary:  "Catch Up",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/checkin", event_checkin_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_checkin + 2
  system(:Mailer)[:last_to].should eq "host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_checkin"]

  # ------------------------------------------------------------------
  # Test 40: guest_event — check-in for an untitled booking (PPT-2535)
  #          bookings without a title or description signal
  #          event_title / event_summary as null. This previously failed
  #          to parse (event_summary was non-nilable) so the exception
  #          was swallowed and the host never received the notification.
  # ------------------------------------------------------------------

  count_before_untitled = system(:Mailer)[:send_count].as_i
  errors_before_untitled = status[:error_count]?.try(&.as_i64) || 0_i64

  untitled_checkin_payload = {
    action:         "checkin",
    id:             902_i64,
    checkin:        true,
    booking_id:     902_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    nil,
    event_summary:  nil,
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/checkin", untitled_checkin_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_untitled + 1
  system(:Mailer)[:last_to].should eq "host@example.com"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "notify_checkin"]
  (status[:error_count]?.try(&.as_i64) || 0_i64).should eq errors_before_untitled

  # ------------------------------------------------------------------
  # Test 41: guest_event — visitor check-out (state=false) does NOT
  #          send the "visitor has arrived" email (PPT-2535)
  # ------------------------------------------------------------------

  count_before_checkout = system(:Mailer)[:send_count].as_i
  checked_in_before_checkout = status[:users_checked_in].as_i64

  checkout_payload = {
    action:         "checkin",
    id:             903_i64,
    checkin:        false,
    booking_id:     903_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Catch Up",
    event_summary:  "Catch Up",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json

  publish("staff/guest/checkin", checkout_payload)
  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_checkout
  status[:users_checked_in].should eq checked_in_before_checkout

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  # ------------------------------------------------------------------
  # Test 42: the host is force-added to the attendee list by staff-api,
  #          so they are signalled like a visitor — skip_host_email must
  #          catch that on the event invite path too.
  # ------------------------------------------------------------------

  count_before_host_invite = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-host-invite",
    event_ical_uid: "ical-host-invite",
    resource:       "room1@example.com",
    event_title:    "Host As Attendee",
    event_summary:  "Host As Attendee",
    event_starting: now + 3600,
    attendee_name:  "Host User",
    attendee_email: "host@example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.5
  system(:Mailer)[:send_count].should eq count_before_host_invite

  # ==================================================================
  # Change notifications carry the QR code and kiosk link
  # ==================================================================
  #
  # A move invalidates the kiosk link issued with the original invitation — its
  # token is scoped to the room the meeting has just left — and no fresh
  # invitation is sent, so the change notification has to carry one.

  # ------------------------------------------------------------------
  # Test 43: event_changed includes guest_jwt, kiosk_url and the QR
  # ------------------------------------------------------------------

  count_before_event_qr = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:             "update",
    system_id:          "sys-room1",
    event_id:           "evt-qr",
    event_ical_uid:     "ical-qr",
    host:               "host@example.com",
    resource:           "room1@example.com",
    title:              "QR Change",
    event_start:        now + 3600,
    event_end:          now + 7200,
    zones:              ["zone-building", "zone-room"],
    previous_system_id: "sys-room2",
  }.to_json)

  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_event_qr + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]

  args43 = system(:Mailer)[:last_args]
  args43["guest_jwt"].as_s.should_not be_empty
  args43["kiosk_url"].as_s.includes?("visitor@external.com").should be_true

  attachments43 = system(:Mailer)[:last_attachments].as_a
  attachments43.size.should eq 1
  attachments43[0]["file_name"].should eq "qr.png"
  attachments43[0]["content_id"].should eq "visitor@external.com"
  # the QR must point at the room the meeting moved TO
  attachments43[0]["content"].as_s.includes?("VISIT:visitor@external.com,sys-room1,evt-qr").should be_true

  # ------------------------------------------------------------------
  # Test 44: booking_changed carries the same
  # ------------------------------------------------------------------

  count_before_booking_qr = system(:Mailer)[:send_count].as_i

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     950_i64,
    booking_type:           "visitor",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host@example.com",
    title:                  "QR Booking Change",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json)

  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_booking_qr + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  args44 = system(:Mailer)[:last_args]
  args44["guest_jwt"].as_s.should_not be_empty
  args44["kiosk_url"].as_s.includes?("event_id=950").should be_true

  attachments44 = system(:Mailer)[:last_attachments].as_a
  attachments44.size.should eq 1
  attachments44[0]["content"].as_s.includes?("VISIT:visitor@external.com,visitor@external.com,950").should be_true

  # ------------------------------------------------------------------
  # Test 45: disable_qr_code drops the attachment but keeps the link
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
    disable_qr_code:    true,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  count_before_no_qr = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:             "update",
    system_id:          "sys-room1",
    event_id:           "evt-no-qr",
    event_ical_uid:     "ical-no-qr",
    host:               "host@example.com",
    resource:           "room1@example.com",
    title:              "No QR Change",
    event_start:        now + 3600,
    event_end:          now + 7200,
    zones:              ["zone-building", "zone-room"],
    previous_system_id: "sys-room2",
  }.to_json)

  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_no_qr + 1
  system(:Mailer)[:last_attachments].as_a.size.should eq 0
  system(:Mailer)[:last_args]["kiosk_url"].as_s.should_not be_empty

  # ------------------------------------------------------------------
  # Test 46: the changed templates expose the kiosk fields so they can be
  #          referenced from the template editor.
  # ------------------------------------------------------------------

  fields = exec(:template_fields).get.as_a
  ["booking_changed", "event_changed"].each do |template_name|
    entry = fields.find { |field| field["trigger"].as_a[1].as_s == template_name }
    entry.should_not be_nil
    names = entry.not_nil!["fields"].as_a.map { |field| field["name"].as_s }
    names.should contain "guest_jwt"
    names.should contain "kiosk_url"
  end

  # ==================================================================
  # Colleagues are not visitors
  # ==================================================================
  #
  # The front-end marks every attendee as an expected visitor, so staff
  # invited to a meeting are signalled exactly like external guests.

  # ------------------------------------------------------------------
  # Test 47: host_domain_filter suppresses the event invite for an
  #          attendee on a filtered (internal) domain.
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
    host_domain_filter: ["example.com"],
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  count_before_domain_filter = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-colleague",
    event_ical_uid: "ical-colleague",
    resource:       "room1@example.com",
    event_title:    "Colleague Added",
    event_summary:  "Colleague Added",
    event_starting: now + 3600,
    attendee_name:  "Colleague",
    attendee_email: "colleague@example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.5
  system(:Mailer)[:send_count].should eq count_before_domain_filter

  # ------------------------------------------------------------------
  # Test 48: skip_internal_domain_email does the same without needing a
  #          domain list — anyone sharing the host's domain is treated as
  #          a colleague.  External visitors are unaffected.
  # ------------------------------------------------------------------

  settings({
    timezone:                   "GMT",
    booking_space_name:         "Client Floor",
    invite_zone_tag:            "building",
    change_debounce:            0,
    skip_internal_domain_email: true,
    domain_uri:                 "https://example.com/",
  })
  sleep 1.0

  count_before_internal = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-internal",
    event_ical_uid: "ical-internal",
    resource:       "room1@example.com",
    event_title:    "Internal Colleague",
    event_summary:  "Internal Colleague",
    event_starting: now + 3600,
    attendee_name:  "Colleague",
    attendee_email: "colleague@example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.5
  system(:Mailer)[:send_count].should eq count_before_internal

  # the external visitor on the same event still gets their invite
  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-internal",
    event_ical_uid: "ical-internal",
    resource:       "room1@example.com",
    event_title:    "Internal Colleague",
    event_summary:  "Internal Colleague",
    event_starting: now + 3600,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.5
  system(:Mailer)[:send_count].should eq count_before_internal + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"

  # and colleagues are dropped from change notifications too
  count_before_internal_change = system(:Mailer)[:send_count].as_i

  internal_guest_booking = {
    action:                 "changed",
    id:                     302_i64,
    booking_type:           "desk",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host@example.com",
    title:                  "Internal Guest Booking",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json

  publish("staff/booking/changed", internal_guest_booking)
  sleep 1.5

  # booking 302 returns colleague@example.com and visitor@external.com — only
  # the visitor is a visitor
  system(:Mailer)[:send_count].should eq count_before_internal_change + 1
  system(:Mailer)[:last_to].should eq "visitor@external.com"

  # ------------------------------------------------------------------
  # Test 49: skip_internal_domain_email is off by default
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  count_before_default_internal = system(:Mailer)[:send_count].as_i

  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-internal-default",
    event_ical_uid: "ical-internal-default",
    resource:       "room1@example.com",
    event_title:    "Internal Default",
    event_summary:  "Internal Default",
    event_starting: now + 3600,
    attendee_name:  "Colleague",
    attendee_email: "colleague@example.com",
    host:           "host@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.5
  system(:Mailer)[:send_count].should eq count_before_default_internal + 1
  system(:Mailer)[:last_to].should eq "colleague@example.com"

  # ... and receives change notifications, as before
  count_before_default_change = system(:Mailer)[:send_count].as_i

  publish("staff/booking/changed", internal_guest_booking)
  sleep 1.5

  system(:Mailer)[:send_count].should eq count_before_default_change + 2

  # ------------------------------------------------------------------
  # Test 50: a host change delivered alongside a time change notifies the
  #          previous host AND renders the NEW host on the change email.
  #
  #          Office365 will not let the organiser of a meeting change, so a
  #          reassignment is reported as a host that differs from
  #          organiser_email, with previous_host_email naming whoever was
  #          hosting before.  The organiser is irrelevant to the visitor.
  # ------------------------------------------------------------------

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    0,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  count_before_host_change = system(:Mailer)[:send_count].as_i

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-new-host",
    event_ical_uid:       "ical-new-host",
    host:                 "new-host@example.com",
    organiser_email:      "old-host@example.com",
    resource:             "room1@example.com",
    title:                "Reassigned And Moved",
    event_start:          now + 7200,
    event_end:            now + 10800,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 3600,
    previous_event_end:   now + 7200,
    previous_host_email:  "old-host@example.com",
  }.to_json)

  sleep 2.0

  # the original host is told, and the visitor's change email names the new host
  system(:Mailer)[:send_count].should eq count_before_host_change + 2
  system(:Mailer)[:sent_templates].as_a[-2].as_s.should eq "notify_original_host"
  system(:Mailer)[:last_template].should eq ["visitor_invited", "event_changed"]
  system(:Mailer)[:last_args]["host_email"].should eq "new-host@example.com"

  # ==================================================================
  # A visitor added by the same edit is not told the visit changed
  # ==================================================================
  #
  # The change and the invitation arrive as separate signals, so the debounce is
  # what gives the driver a chance to correlate them (PPT-2375). Each test uses
  # its own host and start time, as the invite memory outlives the debounce.
  #
  # Assertions read system(:Mailer)[:emails_sent] from a noted index, giving
  # "recipient|template" for just that test's emails.

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    2,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  # ------------------------------------------------------------------
  # Test 51: the QA reproduction — the group booking is updated first,
  #          then the new visitor is added in a later request. Booking
  #          300 with include_linked returns both visitors.
  # ------------------------------------------------------------------

  sent_before_new_visitor = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 7200,
    booking_end:            now + 10800,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-late@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 3600,
    previous_booking_end:   now + 7200,
  }.to_json)

  # still inside the debounce window, as the front end adds its visitors in the
  # requests following the one that moved the booking
  sleep 0.5

  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             1_i64,
    booking_id:     305_i64,
    resource_id:    "visitor-b@external.com",
    resource_ids:   ["visitor-b@external.com"],
    event_title:    "Group Visit",
    event_summary:  "Group Visit",
    event_starting: now + 7200,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "host-late@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  # debounce plus up to one sweep interval
  sleep 8.0

  new_visitor_emails = system(:Mailer)[:emails_sent].as_a[sent_before_new_visitor..].map(&.as_s)

  # the visitor who was already coming is told the details changed
  new_visitor_emails.should contain "visitor-a@external.com|booking_changed"
  # the new visitor gets their invitation
  new_visitor_emails.should contain "visitor-b@external.com|booking"
  # and is not also told that a visit they only just heard about has changed
  new_visitor_emails.should_not contain "visitor-b@external.com|booking_changed"
  new_visitor_emails.size.should eq 2

  # ------------------------------------------------------------------
  # Test 52: the same holds when the invitation lands first (adding the
  #          visitor before saving the new time)
  # ------------------------------------------------------------------

  sent_before_invite_first = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             2_i64,
    booking_id:     306_i64,
    resource_id:    "visitor-b@external.com",
    resource_ids:   ["visitor-b@external.com"],
    event_title:    "Group Visit",
    event_summary:  "Group Visit",
    event_starting: now + 14400,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "host-early@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 14400,
    booking_end:            now + 18000,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-early@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 10800,
    previous_booking_end:   now + 14400,
  }.to_json)

  sleep 8.0

  invite_first_emails = system(:Mailer)[:emails_sent].as_a[sent_before_invite_first..].map(&.as_s)

  invite_first_emails.should contain "visitor-a@external.com|booking_changed"
  invite_first_emails.should contain "visitor-b@external.com|booking"
  invite_first_emails.should_not contain "visitor-b@external.com|booking_changed"
  invite_first_emails.size.should eq 2

  # ------------------------------------------------------------------
  # Test 53: with no visitor added, every visitor is still notified
  # ------------------------------------------------------------------

  sent_before_no_invite = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 21600,
    booking_end:            now + 25200,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-nobody-new@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 18000,
    previous_booking_end:   now + 21600,
  }.to_json)

  sleep 8.0

  no_invite_emails = system(:Mailer)[:emails_sent].as_a[sent_before_no_invite..].map(&.as_s)

  no_invite_emails.should contain "visitor-a@external.com|booking_changed"
  no_invite_emails.should contain "visitor-b@external.com|booking_changed"
  no_invite_emails.size.should eq 2

  # ------------------------------------------------------------------
  # Test 54: an invitation to a different visit doesn't suppress this
  #          one's change notification. Recipients are matched on the
  #          host and the new start, not on the visitor alone.
  # ------------------------------------------------------------------

  sent_before_other_visit = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             3_i64,
    booking_id:     307_i64,
    resource_id:    "visitor-b@external.com",
    resource_ids:   ["visitor-b@external.com"],
    event_title:    "An Unrelated Visit",
    event_summary:  "An Unrelated Visit",
    event_starting: now + 90000,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "someone-else@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 28800,
    booking_end:            now + 32400,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-unrelated@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 25200,
    previous_booking_end:   now + 28800,
  }.to_json)

  sleep 8.0

  other_visit_emails = system(:Mailer)[:emails_sent].as_a[sent_before_other_visit..].map(&.as_s)

  other_visit_emails.should contain "visitor-b@external.com|booking"
  other_visit_emails.should contain "visitor-a@external.com|booking_changed"
  other_visit_emails.should contain "visitor-b@external.com|booking_changed"

  # ------------------------------------------------------------------
  # Test 55: a burst of booking/changed signals for one booking is
  #          coalesced into a single email per visitor
  # ------------------------------------------------------------------

  sent_before_booking_burst = system(:Mailer)[:emails_sent].as_a.size

  3.times do |index|
    publish("staff/booking/changed", {
      action:                 "changed",
      id:                     300_i64,
      booking_type:           "group",
      booking_start:          now + 36000 + index,
      booking_end:            now + 39600 + index,
      timezone:               "GMT",
      resource_id:            "desk-1",
      resource_ids:           ["desk-1"],
      user_email:             "host-burst@example.com",
      title:                  "Group Visit",
      zones:                  ["zone-building", "zone-room"],
      previous_booking_start: now + 32400,
      previous_booking_end:   now + 36000,
    }.to_json)
    sleep 0.2
  end

  sleep 8.0

  booking_burst_emails = system(:Mailer)[:emails_sent].as_a[sent_before_booking_burst..].map(&.as_s)

  booking_burst_emails.size.should eq 2
  # the one email describes the latest values in the burst
  system(:Mailer)[:last_args]["event_time"].should eq Time.unix(now + 36002).in(Time::Location.load("GMT")).to_s("%l:%M%p")

  # ------------------------------------------------------------------
  # Test 56: the same exclusion applies to calendar events
  # ------------------------------------------------------------------

  settings({
    timezone:               "GMT",
    booking_space_name:     "Client Floor",
    invite_zone_tag:        "building",
    change_debounce:        2,
    disable_event_visitors: false,
    domain_uri:             "https://example.com/",
  })
  sleep 1.0

  sent_before_event_invite = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-two-visitors",
    event_ical_uid:       "ical-two-visitors",
    host:                 "host-event@example.com",
    resource:             "room1@example.com",
    title:                "Two Visitors",
    event_start:          now + 46800,
    event_end:            now + 50400,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 43200,
    previous_event_end:   now + 46800,
  }.to_json)

  sleep 0.5

  publish("staff/guest/attending", {
    action:         "meeting_update",
    system_id:      "sys-room1",
    event_id:       "evt-two-visitors",
    event_ical_uid: "ical-two-visitors",
    resource:       "room1@example.com",
    event_title:    "Two Visitors",
    event_summary:  "Two Visitors",
    event_starting: now + 46800,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "host-event@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 8.0

  event_invite_emails = system(:Mailer)[:emails_sent].as_a[sent_before_event_invite..].map(&.as_s)

  event_invite_emails.should contain "visitor-a@external.com|event_changed"
  event_invite_emails.should contain "visitor-b@external.com|event"
  event_invite_emails.should_not contain "visitor-b@external.com|event_changed"
  event_invite_emails.size.should eq 2

  # ------------------------------------------------------------------
  # Test 57: a re-created event-linked visitor booking is not an
  #          invitation, so it must not suppress the change email
  # ------------------------------------------------------------------
  #
  # The front end re-creates the visitor bookings behind a calendar event on
  # every save, and a booking create signals attendance for every attendee. No
  # invite email is sent for an event-linked one, so it is not an invitation.

  settings({
    timezone:                        "GMT",
    booking_space_name:              "Client Floor",
    invite_zone_tag:                 "building",
    change_debounce:                 2,
    skip_event_linked_booking_email: true,
    domain_uri:                      "https://example.com/",
  })
  sleep 1.0

  sent_before_room_move = system(:Mailer)[:emails_sent].as_a.size

  # the room moves; the times are untouched
  publish("staff/event/changed", {
    action:               "update",
    system_id:            "sys-room1",
    event_id:             "evt-room-move",
    event_ical_uid:       "ical-room-move",
    host:                 "host-roommove@example.com",
    resource:             "room1@example.com",
    title:                "Room Moved",
    event_start:          now + 54000,
    event_end:            now + 57600,
    zones:                ["zone-building", "zone-room"],
    previous_event_start: now + 54000,
    previous_event_end:   now + 57600,
    previous_system_id:   "sys-room2",
  }.to_json)

  sleep 0.5

  # booking 601 is event-linked (extension_data.parent_id), so no invite email
  # is sent for it — the visitor was already invited when the event was created
  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             4_i64,
    booking_id:     601_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Room Moved",
    event_summary:  "Room Moved",
    event_starting: now + 54000,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host-roommove@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 8.0

  room_move_emails = system(:Mailer)[:emails_sent].as_a[sent_before_room_move..].map(&.as_s)

  # the visitor is told their meeting moved rooms
  room_move_emails.should contain "visitor@external.com|event_changed"
  # and the event-linked booking still sends no invite of its own
  room_move_emails.should_not contain "visitor@external.com|booking"
  room_move_emails.size.should eq 1

  # ------------------------------------------------------------------
  # Test 58: relocating a booking still notifies the visitor who was
  #          invited when that same booking was created
  # ------------------------------------------------------------------
  #
  # Inviting a visitor and then moving their visit are two separate actions,
  # however close together. A location change leaves the times alone, so the two
  # are indistinguishable by visitor, host and start time alone.

  settings({
    timezone:                        "GMT",
    booking_space_name:              "Client Floor",
    invite_zone_tag:                 "building",
    change_debounce:                 2,
    skip_event_linked_booking_email: true,
    domain_uri:                      "https://example.com/",
  })
  sleep 1.0

  sent_before_relocate = system(:Mailer)[:emails_sent].as_a.size

  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             5_i64,
    booking_id:     600_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Relocated Visit",
    event_summary:  "Relocated Visit",
    event_starting: now + 61200,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host-relocate@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  # the same booking is then moved: the location changes, the times do not
  publish("staff/booking/changed", {
    action:                 "metadata_changed",
    id:                     600_i64,
    booking_type:           "visitor",
    booking_start:          now + 61200,
    booking_end:            now + 64800,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host-relocate@example.com",
    title:                  "Relocated Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 61200,
    previous_booking_end:   now + 64800,
    previous_zones:         ["zone-old-building", "zone-old-room"],
  }.to_json)

  sleep 8.0

  relocate_emails = system(:Mailer)[:emails_sent].as_a[sent_before_relocate..].map(&.as_s)

  relocate_emails.should contain "visitor@external.com|booking"
  relocate_emails.should contain "visitor@external.com|booking_changed"
  relocate_emails.size.should eq 2

  # ------------------------------------------------------------------
  # Test 59: the pre-unification event_change_debounce is still read
  # ------------------------------------------------------------------
  #
  # A deployment that set the old name must not silently fall back to the
  # default, which would both delay and start filtering its notifications.

  settings({
    timezone:              "GMT",
    booking_space_name:    "Client Floor",
    invite_zone_tag:       "building",
    event_change_debounce: 0,
    domain_uri:            "https://example.com/",
  })
  sleep 1.0

  count_before_legacy = system(:Mailer)[:send_count].as_i

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     100_i64,
    booking_type:           "desk",
    booking_start:          now + 86400,
    booking_end:            now + 90000,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-legacy@example.com",
    title:                  "Legacy Debounce",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 82800,
    previous_booking_end:   now + 86400,
  }.to_json)

  sleep 1.0

  system(:Mailer)[:send_count].should eq count_before_legacy + 1
  system(:Mailer)[:last_template].should eq ["visitor_invited", "booking_changed"]

  # ------------------------------------------------------------------
  # Test 60: two visits for the same visitor, host and start time
  # ------------------------------------------------------------------
  #
  # Each invitation has to be remembered on its own. Collapsing them onto one
  # record let the later invitation stand in for the earlier one, so changing
  # the first visit was mistaken for adding the visitor to it.

  settings({
    timezone:           "GMT",
    booking_space_name: "Client Floor",
    invite_zone_tag:    "building",
    change_debounce:    2,
    domain_uri:         "https://example.com/",
  })
  sleep 1.0

  sent_before_two_visits = system(:Mailer)[:emails_sent].as_a.size

  [700_i64, 701_i64].each do |booking_id|
    publish("staff/guest/attending", {
      action:         "booking_created",
      id:             6_i64,
      booking_id:     booking_id,
      resource_id:    "visitor@external.com",
      resource_ids:   ["visitor@external.com"],
      event_title:    "Concurrent Visit",
      event_summary:  "Concurrent Visit",
      event_starting: now + 93600,
      attendee_name:  "Visitor One",
      attendee_email: "visitor@external.com",
      host:           "host-two-visits@example.com",
      zones:          ["zone-building", "zone-room"],
    }.to_json)
    sleep 1.0
  end

  # the first of the two visits is then moved
  publish("staff/booking/changed", {
    action:                 "metadata_changed",
    id:                     700_i64,
    booking_type:           "visitor",
    booking_start:          now + 93600,
    booking_end:            now + 97200,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host-two-visits@example.com",
    title:                  "Concurrent Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 93600,
    previous_booking_end:   now + 97200,
    previous_zones:         ["zone-old-building", "zone-old-room"],
  }.to_json)

  sleep 8.0

  two_visit_emails = system(:Mailer)[:emails_sent].as_a[sent_before_two_visits..].map(&.as_s)

  # the other visit's invitation must not stand in for this one
  two_visit_emails.should contain "visitor@external.com|booking_changed"
  two_visit_emails.count("visitor@external.com|booking").should eq 2

  # ------------------------------------------------------------------
  # Test 61: a visitor invited to both a group container and their own
  #          child booking, in either order
  # ------------------------------------------------------------------
  #
  # Editing a group pushes the member's attendee onto the container as well, so
  # the visitor is announced twice for the one visit. Which announcement landed
  # last must not decide whether their child booking's move reaches them.

  sent_before_leak = system(:Mailer)[:emails_sent].as_a.size

  # the child booking first, then the container — the order that used to lose
  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             7_i64,
    booking_id:     801_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Group Leak",
    event_summary:  "Group Leak",
    event_starting: now + 100800,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host-leak@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  publish("staff/guest/attending", {
    action:         "booking_updated",
    id:             8_i64,
    booking_id:     800_i64,
    resource_id:    "visitor@external.com",
    resource_ids:   ["visitor@external.com"],
    event_title:    "Group Leak",
    event_summary:  "Group Leak",
    event_starting: now + 100800,
    attendee_name:  "Visitor One",
    attendee_email: "visitor@external.com",
    host:           "host-leak@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  # the child booking is moved
  publish("staff/booking/changed", {
    action:                 "metadata_changed",
    id:                     801_i64,
    booking_type:           "visitor",
    booking_start:          now + 100800,
    booking_end:            now + 104400,
    timezone:               "GMT",
    resource_id:            "visitor@external.com",
    resource_ids:           ["visitor@external.com"],
    user_email:             "host-leak@example.com",
    title:                  "Group Leak",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 100800,
    previous_booking_end:   now + 104400,
    previous_zones:         ["zone-old-building", "zone-old-room"],
  }.to_json)

  sleep 8.0

  leak_emails = system(:Mailer)[:emails_sent].as_a[sent_before_leak..].map(&.as_s)

  leak_emails.should contain "visitor@external.com|booking_changed"

  # ------------------------------------------------------------------
  # Test 62: a later, unrelated invitation must not displace the one
  #          that shows the visitor being added to the group
  # ------------------------------------------------------------------
  #
  # Keeping a single invitation per visitor lost whichever arrived first, so an
  # unrelated visit at the same time could mask the fact that this edit is what
  # added them to the group being changed.

  sent_before_evict = system(:Mailer)[:emails_sent].as_a.size

  # added to group 300 by this edit, via their own child booking
  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             9_i64,
    booking_id:     305_i64,
    resource_id:    "visitor-b@external.com",
    resource_ids:   ["visitor-b@external.com"],
    event_title:    "Group Visit",
    event_summary:  "Group Visit",
    event_starting: now + 108000,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "host-evict@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  # and separately invited to an unrelated visit at the same time
  publish("staff/guest/attending", {
    action:         "booking_created",
    id:             10_i64,
    booking_id:     700_i64,
    resource_id:    "visitor-b@external.com",
    resource_ids:   ["visitor-b@external.com"],
    event_title:    "Unrelated Visit",
    event_summary:  "Unrelated Visit",
    event_starting: now + 108000,
    attendee_name:  "Visitor B",
    attendee_email: "visitor-b@external.com",
    host:           "host-evict@example.com",
    zones:          ["zone-building", "zone-room"],
  }.to_json)

  sleep 1.0

  publish("staff/booking/changed", {
    action:                 "changed",
    id:                     300_i64,
    booking_type:           "group",
    booking_start:          now + 108000,
    booking_end:            now + 111600,
    timezone:               "GMT",
    resource_id:            "desk-1",
    resource_ids:           ["desk-1"],
    user_email:             "host-evict@example.com",
    title:                  "Group Visit",
    zones:                  ["zone-building", "zone-room"],
    previous_booking_start: now + 104400,
    previous_booking_end:   now + 108000,
  }.to_json)

  sleep 8.0

  evict_emails = system(:Mailer)[:emails_sent].as_a[sent_before_evict..].map(&.as_s)

  # the visitor already on the group is told
  evict_emails.should contain "visitor-a@external.com|booking_changed"
  # the one this edit added is not, despite the later unrelated invitation
  evict_emails.should_not contain "visitor-b@external.com|booking_changed"
end
