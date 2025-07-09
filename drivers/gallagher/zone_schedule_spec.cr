require "placeos-driver/spec"
require "uuid"

DriverSpecs.mock_driver "Gallagher::ZoneSchedule" do
  system({
    Gallagher: {GallagherMock},
    Bookings:  {BookingsMock},
  })

  # Start a new meeting
  exec(:count).get.should eq 0
  bookings = system(:Bookings).as(BookingsMock)
  bookings.new_meeting
  sleep 500.milliseconds
  exec(:count).get.should eq 1

  # check the update that was applied
  system(:Gallagher)[:state].should eq(["free", "1234"])

  bookings.presence(true)
  sleep 500.milliseconds
  exec(:count).get.should eq 1
  system(:Gallagher)[:state].should eq(["free", "1234"])

  bookings.end_meeting
  sleep 500.milliseconds
  exec(:count).get.should eq 1
  system(:Gallagher)[:state].should eq(["free", "1234"])

  bookings.presence(false)
  sleep 500.milliseconds
  exec(:count).get.should eq 2
  system(:Gallagher)[:state].should eq(["locked", "1234"])

  bookings.disable_unlock
  sleep 500.milliseconds
  exec(:should_unlock_booking?).get.should_not eq true
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def disable_unlock
    self[:current_booking] = {
      extended_properties: {
        "Don't Unlock" => "TRUE",
      },
    }
  end

  def new_meeting : Nil
    self[:status] = "pending"
  end

  def presence(state : Bool)
    self[:presence] = state
  end

  def end_meeting : Nil
    self[:status] = "free"
  end
end

# :nodoc:
class GallagherMock < DriverSpecs::MockDriver
  def free_zone(zone_id : String | Int32)
    self[:state] = {:free, zone_id.to_s}
    true
  end

  def reset_zone(zone_id : String | Int32)
    self[:state] = {:locked, zone_id.to_s}
    true
  end
end
