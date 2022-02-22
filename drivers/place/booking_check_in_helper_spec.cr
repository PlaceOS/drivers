require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  system({
    Bookings: {BookingsMock},
  })

  sleep 1

  system(:Bookings_1)[:current_pending].should eq(false)
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:current_booking] = {
      event_start: 6.minutes.ago.to_unix,
      attendees:   [] of String,
      private:     false,
      all_day:     false,
      attachments: [] of String,
    }
    self[:current_pending] = true
    self[:presence] = true
  end

  def start_meeting(time : Int64)
    self[:current_pending] = false
  end
end
