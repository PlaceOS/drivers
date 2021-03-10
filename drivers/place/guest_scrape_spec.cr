DriverSpecs.mock_driver "Place::GuestScrape" do
  system({
    StaffAPI: {StaffAPI}
  })

  exec(:get_bookings)
end

class StaffAPI < DriverSpecs::MockDriver
  def zone(zone_id : String)
    logger.info { "requesting zone #{zone_id}" }

    {
      id:   zone_id,
      tags: ["level"]
    }
  end
end
