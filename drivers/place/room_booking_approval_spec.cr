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
end

# :nodoc:
# Mimics how the real Bookings module (see bookings.cr poll_events) stores events:
#  - confirmed events go into self[:bookings]
#  - tentative events go into self[:tentative] (and are excluded from :bookings
#    unless @show_tentative_meetings is true, which is false by default)
class BookingsMock < DriverSpecs::MockDriver
  def on_load
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

    self[:tentative] = [{
      event_start: 1.hour.ago.to_unix,
      event_end:   1.hour.from_now.to_unix,
      id:          "tentative-event-id",
      host:        "GradyA@0cbfs.onmicrosoft.com",
      title:       "Approval Test",
      attendees:   [{
        name:            "Approval Room 5",
        email:           "testroom5@0cbfs.onmicrosoft.com",
        response_status: "tentative",
        resource:        true,
      }],
      hide_attendees: false,
      private:        false,
      all_day:        false,
      attachments:    [] of Nil,
      status:         "tentative",
    }]
  end
end

DriverSpecs.mock_driver "Place::RoomBookingApproval" do
  system({
    StaffAPI: {StaffAPIMock},
    Calendar: {CalendarMock},
    Bookings: {BookingsMock},
  })

  sleep 0.5

  exec(:find_bookings_for_approval).get

  approval = status["approval_required"].as_h

  # The tentative event should appear in approval_required.
  # Bug: the driver reads from the "bookings" status (which excludes tentative
  # events by default) instead of the "tentative" status, so this key is missing.
  approval.has_key?("spec_runner_system").should be_true
  events = approval["spec_runner_system"].as_a
  events.size.should eq(1)
  events[0]["id"].should eq("tentative-event-id")
  events[0]["status"].should eq("tentative")
end
