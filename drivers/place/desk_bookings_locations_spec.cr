require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Place::DeskBookingsLocations" do
  system({
    StaffAPI:       {StaffAPI},
    AreaManagement: {AreaManagement},
  })

  now = Time.local
  start = now.at_beginning_of_day.to_unix
  ending = now.at_end_of_day.to_unix

  exec(:query_desk_bookings).get
  resp = exec(:device_locations, "placeos-zone-id").get
  puts resp
  resp.should eq([
    {"location" => "booking", "checked_in" => true, "asset_id" => "desk-123", "booking_id" => 1, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => 1610110799, "mac" => "user-1234", "staff_email" => "user1234@org.com", "staff_name" => "Bob Jane"},
    {"location" => "booking", "checked_in" => false, "asset_id" => "desk-456", "booking_id" => 2, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => 1610110799, "mac" => "user-456", "staff_email" => "zdoo@org.com", "staff_name" => "Zee Doo"},
  ])
end

class StaffAPI < DriverSpecs::MockDriver
  def query_bookings(type : String, zones : Array(String))
    logger.debug { "Querying desk bookings!" }

    now = Time.local
    start = now.at_beginning_of_day.to_unix
    ending = now.at_end_of_day.to_unix
    [{
      id:            1,
      booking_type:  type,
      booking_start: start,
      booking_end:   ending,
      asset_id:      "desk-123",
      user_id:       "user-1234",
      user_email:    "user1234@org.com",
      user_name:     "Bob Jane",
      zones:         zones + ["zone-building"],
      checked_in:    true,
      rejected:      false,
    },
    {
      id:            2,
      booking_type:  type,
      booking_start: start,
      booking_end:   ending,
      asset_id:      "desk-456",
      user_id:       "user-456",
      user_email:    "zdoo@org.com",
      user_name:     "Zee Doo",
      zones:         zones + ["zone-building"],
      checked_in:    false,
      rejected:      false,
    }]
  end

  def zone(zone_id : String)
    logger.info { "requesting zone #{zone_id}" }

    if zone_id == "placeos-zone-id"
      {
        id:   zone_id,
        tags: ["level"],
      }
    else
      {
        id:   zone_id,
        tags: ["building"],
      }
    end
  end
end

class AreaManagement < DriverSpecs::MockDriver
  def update_available(zones : Array(String))
    logger.info { "requested update to #{zones}" }
    nil
  end
end
