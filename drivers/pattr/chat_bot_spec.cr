require "placeos-driver/spec"

DriverSpecs.mock_driver "Pattr::ChatBot" do
  system({
    LocationServices: {LocationServicesMock},
    StaffAPI:         {StaffAPIMock},
  })
  settings({
    buildings: [DriverSpecs::SYSTEM_ID],
  })

  exec(:locate, ["user@org.com"]).get.should eq({"user@org.com" => {
    "building" => "The Zone",
    "level"    => "The Zone",
    "room"     => "Room 1234",
  }})
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def get_system(id : String)
    {
      name:         "Some System",
      display_name: "Room 1234",
    }
  end

  def zone(zone_id : String)
    {
      name: "The Zone",
    }
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def locate_user(email : String? = nil, username : String? = nil)
    [{
      location: "meeting",
      building: "zone-id",
      level:    "zone-id",
      sys_id:   "sys-123",
    }]
  end
end
