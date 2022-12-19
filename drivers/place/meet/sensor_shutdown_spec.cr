require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::SensorShutdown" do
  system({
    Bookings: {BookingsMock},
    System:   {SystemMock},
  })

  sleep 1

  status[:timer_active].should eq(true)
  system(:Bookings_1).as(BookingsMock).sensor_stale

  sleep 1
  status[:timer_active].should eq(false)
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:status] = "free"
    self[:sensor_stale] = false
    self[:presence] = false
  end

  def sensor_stale
    self[:sensor_stale] = true
  end
end

# :nodoc:
class SystemMock < DriverSpecs::MockDriver
  def on_load
    self[:active] = true
  end

  def power(state : Bool)
    self[:active] = state
  end
end
