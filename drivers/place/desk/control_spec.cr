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

  # ===================================================
  # desk assets: desks are keyed by Asset#id
  # ===================================================
  staff_api = system(:StaffAPI).as(StaffAPIMock)
  settings({
    desk_id_key:     "floorsense_id",
    use_desk_assets: true,
  })

  # unmapped keys come from the asset other_data, desks without the key are skipped
  exec(:desk_ids).get.should eq({
    "asset-1" => "fs-1",
    "asset-2" => "fs-2",
  })
  exec(:desk_lookup, "asset-2").get.should eq("fs-2")
  staff_api.asset_requests.should eq [
    {["zone-DnTcV5ZeEq"], nil},
    {["zone-DnTcV5ZeEq"], "page-2"},
  ]

  # mapped desk fields can also be used as the key
  settings({
    desk_id_key:     "map_id",
    use_desk_assets: true,
  })
  exec(:desk_ids).get.should eq({
    "asset-1" => "desk-77123",
    "asset-2" => "desk-006-17",
    "asset-3" => "desk-3",
  })
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter asset_requests = [] of Tuple(Array(String)?, String?)

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    raise "unexpected asset type #{type_id}" unless type_id == "type-desk"
    @asset_requests << {zones, next_page}

    if next_page
      [
        {id: "asset-2", identifier: "test3", map_id: "desk-006-17", zone_id: "zone-EYEnrhbaQz", other_data: {floorsense_id: "fs-2"}},
        {id: "asset-3", identifier: "test4", map_id: "desk-3", zone_id: "zone-EYEnrhbaQz", other_data: {} of String => String},
      ]
    else
      [{id: "asset-1", identifier: "test2", map_id: "desk-77123", zone_id: "zone-EYEnrhbaQz", other_data: {floorsense_id: "fs-1"}, next_page: "page-2"}]
    end
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
