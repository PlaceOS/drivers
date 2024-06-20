require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Desk::Control" do
  system({
    StaffAPI:       {StaffAPIMock},
    AreaManagement: {AreaManagementMock},
  })

  settings({
    desk_id_key: "map_id",
  })

  exec(:desk_ids).get.should eq({
    "desk_77123"  => "desk-77123",
    "desk_006-17" => "desk-006-17",
  })

  exec(:desk_lookup, "desk_77123").get.should eq("desk-77123")
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
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
          "desks": {
            "name":        "desks",
            "description": "List of available desks",
            "details":     [
              {
                "id":       "desk_77123",
                "name":     "test2",
                "groups":   [] of String,
                "images":   [] of String,
                "map_id":   "desk-77123",
                "bookable": false,
                "features": [
                  "test",
                ],
              },
              {
                "id":       "desk_006-17",
                "name":     "test3",
                "groups":   [] of String,
                "images":   [] of String,
                "map_id":   "desk-006-17",
                "bookable": true,
                "features": [] of String,
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
