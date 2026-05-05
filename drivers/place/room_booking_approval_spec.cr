require "placeos-driver/spec"

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def zones(tags : String)
    [{id: "zone-1234"}]
  end

  def systems_in_building(zone_id : String)
    {"zone-level1" => ["spec_runner_system"]}
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def on_load
    self[:accept_event_calls] = 0
    self[:accept_event_args] = nil

    self[:decline_event_calls] = 0
    self[:decline_event_args] = nil

    self[:get_event_calls] = 0
    self[:get_event_args] = nil
  end

  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    self[:accept_event_calls] = self[:accept_event_calls].as_i + 1
    self[:accept_event_args] = {calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment}
    nil
  end

  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    self[:decline_event_calls] = self[:decline_event_calls].as_i + 1
    self[:decline_event_args] = {calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment}
    nil
  end

  def get_event(user_id : String, id : String, calendar_id : String)
    self[:get_event_calls] = self[:get_event_calls].as_i + 1
    self[:get_event_args] = {user_id: user_id, id: id, calendar_id: calendar_id}

    # Return event data that matches PlaceCalendar::Event JSON shape.
    # If the requested id is an occurrence id ("occurrence-of-series-1"),
    # return an event whose recurring_event_id differs from the requested id.
    # Otherwise return the id as-is (it is the series root).
    case id
    when "occurrence-of-series-1"
      {
        event_start:        1.hour.from_now.to_unix,
        event_end:          2.hours.from_now.to_unix,
        id:                 "occurrence-of-series-1",
        recurring_event_id: "series-root-1",
        host:               calendar_id,
        title:              "Occurrence Event",
        attendees:          [] of Nil,
        hide_attendees:     false,
        private:            false,
        all_day:            false,
        attachments:        [] of Nil,
        status:             "tentative",
      }
    else
      {
        event_start:        1.hour.from_now.to_unix,
        event_end:          2.hours.from_now.to_unix,
        id:                 id,
        recurring_event_id: id,
        host:               calendar_id,
        title:              "Series Root Event",
        attendees:          [] of Nil,
        hide_attendees:     false,
        private:            false,
        all_day:            false,
        attachments:        [] of Nil,
        status:             "tentative",
      }
    end
  end
end

# :nodoc:
# Provides tentative events for the approval cache.
# The data set covers:
#   - a standalone tentative event
#   - two events belonging to recurring series "series-root-1"
#   - one event belonging to a different series "series-root-2"
class BookingsMock < DriverSpecs::MockDriver
  TENTATIVE_EVENTS = [
    {
      event_start:        1.hour.from_now.to_unix,
      event_end:          2.hours.from_now.to_unix,
      id:                 "tentative-event-1",
      recurring_event_id: nil,
      host:               "jane@example.com",
      title:              "Standalone Tentative",
      attendees:          [{name: "Room 5", email: "room5@example.com", response_status: "tentative", resource: true}],
      hide_attendees:     false,
      private:            false,
      all_day:            false,
      attachments:        [] of Nil,
      status:             "tentative",
    },
    {
      event_start:        1.day.from_now.to_unix,
      event_end:          (1.day.from_now + 1.hour).to_unix,
      id:                 "tentative-event-2",
      recurring_event_id: "series-root-1",
      host:               "bob@example.com",
      title:              "Weekly Standup (Mon)",
      attendees:          [] of Nil,
      hide_attendees:     false,
      private:            false,
      all_day:            false,
      attachments:        [] of Nil,
      status:             "tentative",
    },
    {
      event_start:        2.days.from_now.to_unix,
      event_end:          (2.days.from_now + 1.hour).to_unix,
      id:                 "tentative-event-3",
      recurring_event_id: "series-root-1",
      host:               "bob@example.com",
      title:              "Weekly Standup (Tue)",
      attendees:          [] of Nil,
      hide_attendees:     false,
      private:            false,
      all_day:            false,
      attachments:        [] of Nil,
      status:             "tentative",
    },
    {
      event_start:        3.days.from_now.to_unix,
      event_end:          (3.days.from_now + 1.hour).to_unix,
      id:                 "tentative-event-4",
      recurring_event_id: "series-root-2",
      host:               "alice@example.com",
      title:              "Design Review",
      attendees:          [] of Nil,
      hide_attendees:     false,
      private:            false,
      all_day:            false,
      attachments:        [] of Nil,
      status:             "tentative",
    },
  ]

  def on_load
    self[:poll_events_calls] = 0

    self[:bookings] = [{
      event_start:    1.hour.ago.to_unix,
      event_end:      1.hour.from_now.to_unix,
      id:             "confirmed-event-id",
      host:           "user@example.com",
      title:          "Confirmed Meeting",
      attendees:      [] of Nil,
      hide_attendees: false,
      private:        false,
      all_day:        false,
      attachments:    [] of Nil,
      status:         "confirmed",
    }]

    self[:tentative] = TENTATIVE_EVENTS
  end

  # Simulates the real Bookings#poll_events: re-polls the calendar and rebuilds
  # the tentative list. In this mock, we filter out events whose id or
  # recurring_event_id appears in the CalendarMock's accepted/declined event list.
  def poll_events
    self[:poll_events_calls] = self[:poll_events_calls].as_i + 1
  end
end

DriverSpecs.mock_driver "Place::RoomBookingApproval" do
  system({
    StaffAPI: {StaffAPIMock},
    Calendar: {CalendarMock},
    Bookings: {BookingsMock},
  })

  # Disable the debounced Bookings re-poll for all sections that don't
  # test it.  This avoids residual timers leaking between test sections.
  settings({
    disable_refresh_bookings: true,
  })

  sleep 0.5

  # ===================================================================
  # find_bookings_for_approval — discovers tentative events
  # ===================================================================

  exec(:find_bookings_for_approval).get

  approval = status["approval_required"].as_h
  approval.has_key?("spec_runner_system").should be_true

  events = approval["spec_runner_system"].as_a
  events.size.should eq(4)

  event_ids = events.map { |e| e["id"].as_s }
  event_ids.should contain("tentative-event-1")
  event_ids.should contain("tentative-event-2")
  event_ids.should contain("tentative-event-3")
  event_ids.should contain("tentative-event-4")

  # Confirmed events must not appear in the approval cache.
  event_ids.should_not contain("confirmed-event-id")

  # All discovered events should have tentative status.
  events.each { |e| e["status"].should eq("tentative") }

  # ===================================================================
  # clear_cache — remove a single standalone event
  # ===================================================================

  exec(:clear_cache, "tentative-event-1").get

  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining.size.should eq(3)
  remaining.map { |e| e["id"].as_s }.should_not contain("tentative-event-1")

  # ===================================================================
  # clear_cache — remove all events in a recurring series
  # ===================================================================

  # Re-populate from Bookings so we have the full set again.
  exec(:find_bookings_for_approval).get

  # Clearing by recurring_event_id should remove every event in that series.
  exec(:clear_cache, "series-root-1").get

  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining_ids = remaining.map { |e| e["id"].as_s }

  # Both occurrences of series-root-1 should be gone.
  remaining_ids.should_not contain("tentative-event-2")
  remaining_ids.should_not contain("tentative-event-3")

  # Events from other series and standalone events are untouched.
  remaining_ids.should contain("tentative-event-1")
  remaining_ids.should contain("tentative-event-4")
  remaining.size.should eq(2)

  # ===================================================================
  # clear_cache(nil) — clear entire cache
  # ===================================================================

  exec(:find_bookings_for_approval).get
  exec(:clear_cache).get

  approval = status["approval_required"].as_h
  approval.size.should eq(0)

  # ===================================================================
  # accept_event — accepts a single event and clears it from cache
  # ===================================================================

  exec(:find_bookings_for_approval).get

  exec(:accept_event,
    calendar_id: "room5@example.com",
    event_id: "tentative-event-1",
  ).get

  # Verify Calendar.accept_event was called with correct arguments.
  system(:Calendar_1)[:accept_event_calls].should eq(1)
  accept_args = system(:Calendar_1)[:accept_event_args].as_h
  accept_args["calendar_id"].should eq("room5@example.com")
  accept_args["event_id"].should eq("tentative-event-1")

  # The accepted event should be removed from the approval cache.
  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining.map { |e| e["id"].as_s }.should_not contain("tentative-event-1")
  remaining.size.should eq(3)

  # ===================================================================
  # decline_event — declines a single event and clears it from cache
  # ===================================================================

  exec(:decline_event,
    calendar_id: "room5@example.com",
    event_id: "tentative-event-4",
  ).get

  # Verify Calendar.decline_event was called.
  system(:Calendar_1)[:decline_event_calls].should eq(1)
  decline_args = system(:Calendar_1)[:decline_event_args].as_h
  decline_args["calendar_id"].should eq("room5@example.com")
  decline_args["event_id"].should eq("tentative-event-4")

  # The declined event should be removed from the approval cache.
  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining.map { |e| e["id"].as_s }.should_not contain("tentative-event-4")
  remaining.size.should eq(2)

  # ===================================================================
  # accept_event / decline_event — also trigger debounced Bookings re-poll
  # ===================================================================

  settings({
    disable_refresh_bookings: false,
  })

  sleep 0.5

  exec(:find_bookings_for_approval).get

  poll_before = system(:Bookings_1)[:poll_events_calls].as_i

  exec(:accept_event,
    calendar_id: "room5@example.com",
    event_id: "tentative-event-1",
  ).get

  exec(:decline_event,
    calendar_id: "room5@example.com",
    event_id: "tentative-event-4",
  ).get

  sleep 11

  # The debounced refresh should have triggered poll_events.
  system(:Bookings_1)[:poll_events_calls].as_i.should be >= (poll_before + 1)

  # Re-disable for the remaining non-debounce tests.
  settings({
    disable_refresh_bookings: true,
  })

  sleep 0.5

  # ===================================================================
  # accept_recurring_event — with check_recurring_event_id: false (default)
  # Accepts a series by recurring_event_id and clears all occurrences.
  # ===================================================================

  exec(:find_bookings_for_approval).get

  exec(:accept_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "series-root-1",
  ).get

  # Calendar.accept_event should be called with the series root id.
  accept_args = system(:Calendar_1)[:accept_event_args].as_h
  accept_args["event_id"].should eq("series-root-1")

  # get_event should NOT have been called (check_recurring_event_id is false).
  system(:Calendar_1)[:get_event_calls].should eq(0)

  # All events in the series should be removed from the approval cache.
  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining_ids = remaining.map { |e| e["id"].as_s }
  remaining_ids.should_not contain("tentative-event-2")
  remaining_ids.should_not contain("tentative-event-3")

  # The standalone event and the other series are untouched.
  remaining_ids.should contain("tentative-event-1")
  remaining_ids.should contain("tentative-event-4")

  # ===================================================================
  # decline_recurring_event — with check_recurring_event_id: false
  # ===================================================================

  exec(:find_bookings_for_approval).get

  exec(:decline_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "series-root-2",
  ).get

  decline_args = system(:Calendar_1)[:decline_event_args].as_h
  decline_args["event_id"].should eq("series-root-2")

  system(:Calendar_1)[:get_event_calls].should eq(0)

  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining.map { |e| e["id"].as_s }.should_not contain("tentative-event-4")

  # ===================================================================
  # accept_recurring_event — with check_recurring_event_id: true
  # When an occurrence id is passed, it should resolve to the series root
  # via get_event before accepting.
  # ===================================================================

  settings({
    check_recurring_event_id: true,
    disable_refresh_bookings: true,
  })

  sleep 0.5

  exec(:find_bookings_for_approval).get

  exec(:accept_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "occurrence-of-series-1",
  ).get

  # get_event should have been called to resolve the occurrence id.
  system(:Calendar_1)[:get_event_calls].should eq(1)
  get_args = system(:Calendar_1)[:get_event_args].as_h
  get_args["id"].should eq("occurrence-of-series-1")

  # Calendar.accept_event should have been called with the RESOLVED series root id,
  # not the occurrence id that was originally passed in.
  accept_args = system(:Calendar_1)[:accept_event_args].as_h
  accept_args["event_id"].should eq("series-root-1")

  # All events in the series should be removed from the cache.
  approval = status["approval_required"].as_h
  remaining = approval["spec_runner_system"].as_a
  remaining_ids = remaining.map { |e| e["id"].as_s }
  remaining_ids.should_not contain("tentative-event-2")
  remaining_ids.should_not contain("tentative-event-3")

  # ===================================================================
  # accept_recurring_event — with check_recurring_event_id: true
  # When the id IS already the series root, it should pass it through.
  # ===================================================================

  exec(:find_bookings_for_approval).get

  exec(:accept_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "series-root-1",
  ).get

  # get_event is called, but the returned recurring_event_id matches the input,
  # so the original id is used as-is.
  accept_args = system(:Calendar_1)[:accept_event_args].as_h
  accept_args["event_id"].should eq("series-root-1")

  # ===================================================================
  # decline_recurring_event — with check_recurring_event_id: true
  # ===================================================================

  exec(:find_bookings_for_approval).get

  exec(:decline_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "occurrence-of-series-1",
  ).get

  # Should have resolved the occurrence to the series root before declining.
  decline_args = system(:Calendar_1)[:decline_event_args].as_h
  decline_args["event_id"].should eq("series-root-1")

  # ===================================================================
  # Fix D — Bookings re-poll is debounced
  # After accepting/declining a recurring series the driver schedules a
  # Bookings poll_events call with a 10-second debounce.  Multiple
  # actions within the window should be batched into a single poll.
  # ===================================================================

  settings({
    check_recurring_event_id: false,
    disable_refresh_bookings: false,
  })

  sleep 0.5

  exec(:find_bookings_for_approval).get

  poll_before = system(:Bookings_1)[:poll_events_calls].as_i

  # Accept and decline two different series in quick succession.
  # Both should be batched by the debounce timer into a single poll.
  exec(:accept_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "series-root-1",
  ).get

  exec(:decline_recurring_event,
    calendar_id: "room5@example.com",
    recurring_event_id: "series-root-2",
  ).get

  # Wait for the debounce timer to fire (default 10 s + margin).
  sleep 11

  # The debounced refresh should have triggered poll_events at least once.
  system(:Bookings_1)[:poll_events_calls].as_i.should be >= (poll_before + 1)

  # ===================================================================
  # resolve_recurring_event_id — returns series root when ids differ
  # ===================================================================

  result = exec(:resolve_recurring_event_id,
    calendar_id: "room5@example.com",
    event_id: "occurrence-of-series-1",
  ).get

  result.should eq("series-root-1")

  # ===================================================================
  # resolve_recurring_event_id — returns input when id is already root
  # ===================================================================

  result = exec(:resolve_recurring_event_id,
    calendar_id: "room5@example.com",
    event_id: "series-root-1",
  ).get

  result.should eq("series-root-1")
end
