require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::DeskBookingsLocations" do
  system({
    StaffAPI:         {StaffAPIMock},
    AreaManagement:   {AreaManagementMock},
    LocationServices: {LocationServicesMock},
  })

  base_settings = {
    zone_filter: ["placeos-zone-id"],
  }
  settings(base_settings)
  staff_api = system(:StaffAPI).as(StaffAPIMock)

  now = Time.local
  start = now.at_beginning_of_day.to_unix
  ending = now.at_end_of_day.to_unix

  # metadata mode: bookings reference the metadata desk ids
  exec(:query_desk_bookings).get
  resp = exec(:device_locations, "placeos-zone-id").get
  puts resp
  resp.should eq([
    {"location" => "booking", "type" => "desk", "checked_in" => true, "asset_id" => "desk-123", "booking_id" => 1, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => ending, "started_at" => start, "duration" => 86399, "mac" => "user-1234", "staff_email" => "user1234@org.com", "staff_name" => "Bob Jane", "map_id" => "meta-map-123"},
    {"location" => "booking", "type" => "desk", "checked_in" => false, "asset_id" => "desk-456", "booking_id" => 2, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => ending, "started_at" => start, "duration" => 86399, "mac" => "user-456", "staff_email" => "zdoo@org.com", "staff_name" => "Zee Doo", "map_id" => "meta-map-456"},
  ])
  staff_api.asset_calls.should eq 0

  # assets mode: bookings reference the Asset#id, map ids come from the assets (two pages)
  staff_api.migrate_bookings
  settings(base_settings.merge({use_desk_assets: true}))
  exec(:query_desk_bookings).get
  resp = exec(:device_locations, "placeos-zone-id").get
  puts resp
  resp.should eq([
    {"location" => "booking", "type" => "desk", "checked_in" => true, "asset_id" => "asset-123", "booking_id" => 1, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => ending, "started_at" => start, "duration" => 86399, "mac" => "user-1234", "staff_email" => "user1234@org.com", "staff_name" => "Bob Jane", "map_id" => "asset-map-123"},
    {"location" => "booking", "type" => "desk", "checked_in" => false, "asset_id" => "asset-456", "booking_id" => 2, "building" => "zone-building", "level" => "placeos-zone-id", "ends_at" => ending, "started_at" => start, "duration" => 86399, "mac" => "user-456", "staff_email" => "zdoo@org.com", "staff_name" => "Zee Doo", "map_id" => "asset-map-456"},
  ])
  staff_api.asset_calls.should eq 2
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter use_asset_ids : Bool = false
  getter asset_calls : Int32 = 0

  # bookings reference the Asset#id once desks are migrated
  def migrate_bookings : Nil
    @use_asset_ids = true
  end

  def metadata_children(id : String, key : String? = nil)
    raise "unexpected building #{id}" unless id == "zone-building"
    [
      {
        zone:     {id: "placeos-zone-id"},
        metadata: {
          desks: {
            details: [
              {id: "desk-123", name: "Desk 123", map_id: "meta-map-123"},
              {id: "desk-456", name: "Desk 456", map_id: "meta-map-456"},
            ],
          },
        },
      },
    ]
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}, {id: "type-other", name: "Lockers"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    @asset_calls += 1
    raise "unexpected asset query" unless type_id == "type-desk" && zones == ["zone-building"]
    if next_page == "page-2"
      [{id: "asset-456", identifier: "desk-456", map_id: "asset-map-456", zone_id: "placeos-zone-id", zones: ["zone-building", "placeos-zone-id"]}]
    else
      [{id: "asset-123", identifier: "desk-123", map_id: "asset-map-123", zone_id: "placeos-zone-id", zones: ["zone-building", "placeos-zone-id"], next_page: "page-2"}]
    end
  end

  def query_bookings(type : String, zones : Array(String) = [] of String, period_start : Int64? = nil, period_end : Int64? = nil)
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
        asset_id:        use_asset_ids ? "asset-123" : "desk-123",
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
        asset_id:        use_asset_ids ? "asset-456" : "desk-456",
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

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def update_available(zones : Array(String))
    logger.info { "requested update to #{zones}" }
    nil
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def building_id : String
    "zone-building"
  end
end
