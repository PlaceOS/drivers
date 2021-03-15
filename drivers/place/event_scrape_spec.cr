DriverSpecs.mock_driver "Place::EventScrape" do
  system({
    StaffAPI: {StaffAPI}
  })

  exec(:get_bookings)
end

class StaffAPI < DriverSpecs::MockDriver
  def systems(zone_id : String)
    logger.info { "requesting zone #{zone_id}" }

    sys_1 = {
      id: "sys-1",
      name: "Room 1",
      zones: ["placeos-zone-id"]
    }

    if zone_id == "placeos-zone-id"
      [sys_1]
    else
      [
        sys_1,
        {
          id: "sys-2",
          name: "Room 2",
          zones: ["zone-1"]
        }
      ]
    end
  end

  def modules_from_system(system_id : String)
    [
      {
        id: "mod-1",
        control_system_id: system_id,
        name: "Calendar"
      },
      {
        id: "mod-2",
        control_system_id: system_id,
        name: "Bookings"
      },
      {
        id: "mod-3",
        control_system_id: system_id,
        name: "Bookings"
      }
    ]
  end

  def get_module_state(module_id : String, lookup : String? = nil)
    now = Time.local
    start = now.at_beginning_of_day.to_unix
    ending = now.at_end_of_day.to_unix

    {
      bookings: [{
        event_start: start,
        event_end: ending,
        id: "booking-1",
        host: "testroom1@booking.demo.acaengine.com",
        title: "Test in #{module_id}"
      }].to_json
    }
  end
end
