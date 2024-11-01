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
  sleep 1
  exec(:count).get.should eq 1

  # check the update that was applied
  system(:Gallagher)[:freed].should eq("1234")
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def new_meeting : Nil
    self[:status] = "pending"
  end
end

# :nodoc:
class GallagherMock < DriverSpecs::MockDriver
  def free_zone(zone_id : String | Int32)
    self[:freed] = zone_id.to_s
    true
  end
end
