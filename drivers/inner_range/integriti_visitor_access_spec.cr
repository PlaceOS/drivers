require "placeos-driver/spec"

DriverSpecs.mock_driver "InnerRange::IntegritiHIDVirtualPass" do
  system({
    StaffAPI:  {StaffAPIMock},
    Integriti: {IntegritiMock},
  })
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def zone(id : String)
    {
      name: "Building 1234",
    }
  end
end

# :nodoc:
class IntegritiMock < DriverSpecs::MockDriver
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
end

# :nodoc:
class LocationsMock < DriverSpecs::MockDriver
  def building_id : String
    "building-1234"
  end
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
end
