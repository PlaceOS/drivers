require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::AreaManagement" do
  system({
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
  })

  base_settings = {
    building_zone_override: "zone-building",
    desk_id_mappings:       ["floorsensedeskid"],
    include_sensors:        false,
    poll_rate:              600,
    areas:                  {
      "zone-1234" => [
        {
          id:          "lobby1",
          name:        "George St Lobby",
          building:    "building-zone-id",
          coordinates: [{3, 5}, {5, 6}, {6, 1}],
        },
      ],
    },
  }
  settings(base_settings)

  # Used this tool to work out coordinates: https://www.mathsisfun.com/geometry/polygons-interactive.html
  exec(:is_inside?, 4, 5, "lobby1").get.should eq(true)
  exec(:is_inside?, 4, 4, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 5, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 4, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 3, "lobby1").get.should eq(true)
  exec(:is_inside?, 3.1, 5, "lobby1").get.should eq(true)

  exec(:is_inside?, 3, 6, "lobby1").get.should eq(false)
  exec(:is_inside?, 4, 6, "lobby1").get.should eq(false)
  exec(:is_inside?, 4.6, 5.9, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.2, 5.4, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.5, 1.5, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.9, 2, "lobby1").get.should eq(false)

  staff_api = system(:StaffAPI).as(StaffAPIMock)

  # ===================================================
  # desk metadata
  # ===================================================
  # the scheduler syncs the building on load (rate limited to every 3 seconds)
  sleep 4.seconds
  staff_api.children_requests.should contain({"zone-building", nil})
  staff_api.children_requests.should contain({"zone-building", "desks"})
  staff_api.asset_requests.should be_empty

  exec(:request_level_locations, "zone-level-1").get
  status["zone-level-1:desk_ids"].should eq ["desk-1", "desk-2"]
  # the floorsense desk id is mapped to the metadata desk
  locations = status["zone-level-1"]["value"].as_a
  locations.map(&.["map_id"]).should eq ["desk-1", "desk-2", "desk-1"]
  status["zone-level-1:desk_bookings"]["desk-1"].as_a.map(&.["booking_id"]).should eq [1]
  status[:overview]["zone-level-1"]["desk_count"].should eq 2
  status[:overview]["zone-level-1"]["desk_usage"].should eq 1

  # ===================================================
  # desk assets
  # ===================================================
  staff_api.reset
  settings(base_settings.merge({use_desk_assets: true}))
  exec(:synchronize_all_levels).get
  sleep 4.seconds

  # building desks come from both pages of assets, other metadata is still used
  staff_api.children_requests.should eq [{"zone-building", nil}]
  staff_api.asset_requests.should contain({["zone-building"], nil, nil})
  staff_api.asset_requests.should contain({["zone-building"], nil, "page-2"})
  staff_api.asset_requests.should contain({nil, "zone-level-1", nil})

  exec(:request_level_locations, "zone-level-1").get
  # assets are placed on the map using their map_id
  status["zone-level-1:desk_ids"].should eq ["table-1", "table-2"]
  locations = status["zone-level-1"]["value"].as_a
  locations.map(&.["map_id"]).should eq ["table-1", "table-2", "table-1"]
  # bookings without a map_id are keyed by the Asset#id
  status["zone-level-1:desk_bookings"]["asset-2"].as_a.map(&.["booking_id"]).should eq [2]
  status[:overview]["zone-level-1"]["desk_count"].should eq 2
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter children_requests = [] of Tuple(String, String?)
  getter asset_requests = [] of Tuple(Array(String)?, String?, String?)

  def reset
    @children_requests.clear
    @asset_requests.clear
  end

  LEVEL = {
    id:         "zone-level-1",
    name:       "Level 1",
    count:      0,
    capacity:   20,
    tags:       ["level"],
    triggers:   [] of String,
    parent_id:  "zone-building",
    created_at: 1,
    updated_at: 1,
  }

  DESKS = [
    {id: "desk-1", name: "Desk 1", floorsensedeskid: "fs-1"},
    {id: "desk-2", name: "Desk 2", floorsensedeskid: "fs-2"},
  ]

  def zone(zone_id : String)
    LEVEL.merge({id: zone_id})
  end

  def zones(q : String? = nil, limit : Int32 = 1000, offset : Int32 = 0, parent : String? = nil, tags : Array(String) | String? = nil)
    [] of Nil
  end

  protected def level_metadata(key : String?)
    meta = {} of String => JSON::Any
    if key.nil? || key == "desks"
      meta["desks"] = JSON.parse({name: "desks", description: "", parent_id: "zone-level-1", details: DESKS}.to_json)
    end
    meta
  end

  def metadata(id : String, key : String? = nil)
    level_metadata(key)
  end

  def metadata_children(id : String, key : String? = nil)
    @children_requests << {id, key}
    [{zone: LEVEL, metadata: level_metadata(key)}]
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    raise "unexpected asset type #{type_id}" unless type_id == "type-desk"
    @asset_requests << {zones, zone_id, next_page}

    if next_page
      [{id: "asset-2", identifier: "desk-2", map_id: "table-2", zone_id: "zone-level-1", other_data: {floorsensedeskid: "fs-2"}}]
    else
      [{id: "asset-1", identifier: "desk-1", map_id: "table-1", zone_id: "zone-level-1", other_data: {floorsensedeskid: "fs-1"}, next_page: "page-2"}]
    end
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def device_locations(zone_id : String, location : String? = nil)
    [
      {location: "desk", map_id: "fs-1", at_location: 1, level: zone_id},
      {location: "desk", map_id: "fs-2", at_location: 0, level: zone_id},
      {location: "booking", type: "desk", map_id: "fs-1", checked_in: true, level: zone_id},
    ]
  end

  def upcoming_bookings(zone_id : String)
    [
      {location: "booking", type: "desk", map_id: "desk-1", booking_id: 1, started_at: 10},
      {location: "booking", type: "desk", asset_id: "asset-2", booking_id: 2, started_at: 20},
    ]
  end

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil)
    [] of Nil
  end
end
