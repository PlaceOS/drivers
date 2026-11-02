require "placeos-driver/spec"
require "./models"

DriverSpecs.mock_driver "GoBright::LocationService" do
  system({
    GoBright:       {GoBrightMock},
    StaffAPI:       {StaffAPIMock},
    AreaManagement: {AreaManagementMock},
  })

  base_settings = {
    gobright_floor_mappings: {
      "placeos_zone_id": {
        location_id: "level",
        name:        "friendly name for documentation",
      },
    },
    return_empty_spaces: true,
    desk_space_types:    ["desk"],
    space_cache_cron:    "0 5 * * *",
  }
  staff_api = system(:StaffAPI).as(StaffAPIMock)

  # ===================================================
  # desk metadata
  # ===================================================
  exec(:device_locations, "placeos_zone_id").get.should eq([
    {
      "location"             => "desk",
      "at_location"          => 0,
      "map_id"               => "desk-1",
      "level"                => "placeos_zone_id",
      "building"             => "zone-1234",
      "capacity"             => 1,
      "group"                => "HR",
      "gobright_location_id" => "level",
      "gobright_space_name"  => "desk-1",
      "gobright_space_type"  => "desk",
      "gobright_space_id"    => "space-1234",
    }, {
      "location"             => "area",
      "at_location"          => 1,
      "map_id"               => "room-1",
      "level"                => "placeos_zone_id",
      "building"             => "zone-1234",
      "capacity"             => 1,
      "group"                => "none",
      "gobright_location_id" => "level",
      "gobright_space_name"  => "room-1",
      "gobright_space_type"  => "room",
      "gobright_space_id"    => "space-4567",
    },
  ])

  # ===================================================
  # desk assets
  # ===================================================
  settings(base_settings.merge({use_desk_assets: true}))

  # the gobright desk name is read from the asset client_ids, departments from other_data
  locations = exec(:device_locations, "placeos_zone_id").get.not_nil!.as_a
  locations.map { |loc| {loc["map_id"], loc["group"]} }.should eq [{"desk-1", "Finance"}, {"room-1", "none"}]
  staff_api.asset_requests.should eq [nil, "page-2"]
end

# :nodoc:
class GoBrightMock < DriverSpecs::MockDriver
  def spaces(location : String? = nil, types : GoBright::SpaceType | Array(GoBright::SpaceType)? = nil)
    [
      {
        id:         "space-1234",
        locationId: "level",
        name:       "desk-1",
        type:       1,
      },
      {
        id:         "space-4567",
        locationId: "level",
        name:       "room-1",
        type:       0,
      },
    ]
  end

  def live_occupancy(location : String? = nil, type : GoBright::SpaceType? = nil)
    [
      {
        spaceId:            "space-1234",
        occupationDetected: false,
      },
      {
        spaceId:            "space-4567",
        occupationDetected: true,
      },
    ]
  end

  def bookings(starting : Int64, ending : Int64, location_id : String | Array(String)? = nil, space_id : String | Array(String)? = nil)
    [] of Nil
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter asset_requests : Array(String?) = [] of String?

  def zones(tags : String)
    logger.info { "zones requested from staff api" }
    raise "unexpected tags, expected building, got: #{tags}" unless tags == "building"

    # NOTE:: zone-1234 is the default zone used in the spec runner
    [{id: "zone-1234"}]
  end

  def metadata(id : String, key : String? = nil)
    logger.info { "metadata requested from staff api" }

    {
      "desks": {
        "name":        "desks",
        "description": "",
        "details":     [
          {
            "id":                 "table-07.001.status",
            "name":               "Desk 07.001",
            "departments":        ["HR"],
            "map_id":             "table-07.001.status",
            "bookable":           true,
            "gobright_desk_name": "desk-1",
          },
          # desks without a gobright desk name are ignored
          {
            "id":     "table-07.002.status",
            "name":   "Desk 07.002",
            "map_id": "table-07.002.status",
          },
        ],
      },
    }
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    raise "unexpected asset request #{type_id} #{zone_id}" unless type_id == "type-desk" && zone_id == "placeos_zone_id"
    @asset_requests << next_page

    if next_page
      [{id: "asset-2", identifier: "Desk 07.002", map_id: "table-07.002.status", zone_id: zone_id, client_ids: {} of String => String}]
    else
      [{
        id:         "asset-1",
        identifier: "Desk 07.001",
        map_id:     "table-07.001.status",
        zone_id:    zone_id,
        client_ids: {gobright_desk_name: "desk-1"},
        other_data: {departments: ["Finance"]},
        next_page:  "page-2",
      }]
    end
  end
end

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def level_details
    {} of String => String
  end
end
