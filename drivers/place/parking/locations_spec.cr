require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Parking::Locations" do
  system({
    StaffAPI:       {StaffAPIMock},
    AreaManagement: {AreaManagementMock},
  })

  exec(:parking_spaces).get.should eq({
    "zone-EYEnrhbaQz" => [
      {
        "id"     => "park-001",
        "name"   => "Bay 001",
        "map_id" => "park-001",
      },
      {
        "id"            => "parking-zone-FlWVOXv9yY.472179",
        "name"          => "Bay 005 Test",
        "map_id"        => "park-005",
        "assigned_to"   => "AdeleV@0cbfs.onmicrosoft.com",
        "assigned_name" => "Adele Vance",
      },
    ],
  })
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def query_bookings(type : String, zones : Array(String))
    logger.debug { "Querying desk bookings!" }

    now = Time.local
    start = now.at_beginning_of_day.to_unix
    ending = now.at_end_of_day.to_unix
    [
      {
        id:              1,
        booking_type:    type,
        booking_start:   start,
        booking_end:     ending,
        asset_id:        "desk-123",
        user_id:         "user-1234",
        user_email:      "user1234@org.com",
        user_name:       "Bob Jane",
        zones:           zones + ["zone-building"],
        checked_in:      true,
        rejected:        false,
        booked_by_name:  "Bob Jane",
        booked_by_email: "user1234@org.com",
      },
      {
        id:              2,
        booking_type:    type,
        booking_start:   start,
        booking_end:     ending,
        asset_id:        "desk-456",
        user_id:         "user-456",
        user_email:      "zdoo@org.com",
        user_name:       "Zee Doo",
        zones:           zones + ["zone-building"],
        checked_in:      false,
        rejected:        false,
        booked_by_name:  "Zee Doo",
        booked_by_email: "zdoo@org.com",
      },
    ]
  end

  def metadata_children(id : String, key : String? = nil)
    logger.info { "requesting zone #{id} and key #{key}" }

    [
      {
        "zone": {
          "created_at":   1668744303,
          "updated_at":   1668744303,
          "id":           "zone-FlWVOXv9yY",
          "name":         "PlaceOS Dev Sydney Catering Enabled",
          "display_name": "Catering ",
          "location":     "",
          "description":  "",
          "code":         "",
          "type":         "",
          "count":        0,
          "capacity":     0,
          "map_id":       "",
          "tags":         [] of String,
          "triggers":     [] of String,
          "parent_id":    "zone-DnTcV5ZeEq",
        },
        "metadata": {} of String => String,
      },
      {
        "zone": {
          "created_at":   1691972553,
          "updated_at":   1701398359,
          "id":           "zone-EYEnrhbaQz",
          "name":         "LEVEL  Parking",
          "display_name": "Parking",
          "location":     "",
          "description":  "",
          "code":         "",
          "type":         "",
          "count":        0,
          "capacity":     0,
          "map_id":       "https://s3-ap-southeast-2.amazonaws.com/os.place.tech/placeos-dev.aca.im/169197263162476823.svg",
          "tags":         [
            "level",
            "parking",
          ],
          "triggers":  [] of String,
          "parent_id": "zone-DnTcV5ZeEq",
        },
        "metadata": {
          "parking-spaces": {
            "name":        "parking-spaces",
            "description": "List of available parking spaces",
            "details":     [
              {
                "id":            "park-001",
                "name":          "Bay 001",
                "notes":         "notes new",
                "map_id":        "park-001",
                "assigned_to":   nil,
                "map_rotation":  0,
                "assigned_name": nil,
                "assigned_user": nil,
              },
              {
                "id":            "parking-zone-FlWVOXv9yY.472179",
                "name":          "Bay 005 Test",
                "notes":         "",
                "map_id":        "park-005",
                "assigned_to":   "AdeleV@0cbfs.onmicrosoft.com",
                "map_rotation":  0,
                "assigned_name": "Adele Vance",
              },
            ],
            "parent_id":      "zone-FlWVOXv9yY",
            "editors":        [] of String,
            "modified_by_id": "user-DGLTbVU8eqiSRn",
          },
        },
      },
    ]
  end
end

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def update_available(zones : Array(String))
    logger.info { "requested update to #{zones}" }
    nil
  end

  def level_buildings
    {
      "zone-EYEnrhbaQz": "zone-DnTcV5ZeEq",
    }
  end
end
