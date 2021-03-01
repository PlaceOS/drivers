DriverSpecs.mock_driver "XYSense::LocationService" do
  system({
    XYSense:        {XYSense},
    AreaManagement: {AreaManagement},
  })

  now = Time.local
  start = now.at_beginning_of_day.to_unix
  ending = now.at_end_of_day.to_unix

  resp = exec(:device_locations, "placeos-zone-id").get
  puts resp
  resp.should eq([
    {"location" => "desk", "at_location" => 1, "map_id" => "desk-456", "level" => "placeos-zone-id", "capacity" => 1, "xy_sense_space_id" => "xysense-desk-456-id", "xy_sense_status" => "recentlyOccupied", "xy_sense_collected" => 1605088820, "xy_sense_category" => "Workpoint"},
    {"location" => "area", "at_location" => 8, "map_id" => "area-567", "level" => "placeos-zone-id", "capacity" => 20, "xy_sense_space_id" => "xysense-area-567-id", "xy_sense_status" => "currentlyOccupied", "xy_sense_collected" => 1605088820, "xy_sense_category" => "Lobby"},
  ])
end

class XYSense < DriverSpecs::MockDriver
  def on_load
    self[:floors] = {
      "xy-sense-floor-id" => {
        floor_id:      "xy-sense-floor-id",
        floor_name:    "Fancy floor",
        location_id:   "xysense-building",
        location_name: "Fancy building",
        spaces:        [{
          id:       "xysense-desk-123-id",
          name:     "desk-123",
          capacity: 1,
          category: "Workpoint",
        },
        {
          id:       "xysense-desk-456-id",
          name:     "desk-456",
          capacity: 1,
          category: "Workpoint",
        },
        {
          id:       "xysense-area-567-id",
          name:     "area-567",
          capacity: 20,
          category: "Lobby",
        }],
      },
    }

    self["xy-sense-floor-id"] = [
      {
        status:    "notOccupied",
        headcount: 0,
        space_id:  "xysense-desk-123-id",
        collected: "2020-11-11T10:00:20",
      },
      {
        status:    "recentlyOccupied",
        headcount: 1,
        space_id:  "xysense-desk-456-id",
        collected: "2020-11-11T10:00:20",
      },
      {
        status:    "currentlyOccupied",
        headcount: 8,
        space_id:  "xysense-area-567-id",
        collected: "2020-11-11T10:00:20",
      },
    ]
  end
end

class AreaManagement < DriverSpecs::MockDriver
  def update_available(zones : Array(String))
    logger.info { "requested update to #{zones}" }
    nil
  end
end
