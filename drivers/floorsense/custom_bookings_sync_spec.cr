require "placeos-driver/spec"
require "./models"

class StaffAPIMock < DriverSpecs::MockDriver
  def metadata(id : String, key : String? = nil)
    JSON.parse({
      desks: {
        name:      "desks",
        parent_id: id,
        details:   [
          {id: "desk-1", name: "Desk 1", floorsense_id: "fs-1", neighbourhoodID: "north", features: ["standing"]},
          {id: "desk-2", name: "Desk 2", floorsense_id: "fs-2"},
          # no floorsense id, not synced
          {id: "desk-3", name: "Desk 3"},
        ],
      },
    }.to_json)
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    JSON.parse([{id: "type-desk", name: "_DESKS_"}].to_json)
  end

  def assets(
    type_id : String? = nil,
    zone_id : String? = nil,
    order_id : String? = nil,
    barcode : String? = nil,
    serial_number : String? = nil,
    bookable : Bool? = nil,
    accessible : Bool? = nil,
    features : Array(String)? = nil,
    zones : Array(String)? = nil,
    limit : Int32 = 1000,
    next_page : String? = nil,
  )
    return JSON.parse("[]") unless type_id == "type-desk" && zone_id == "zone-level"

    if next_page == "page-2"
      JSON.parse([
        {id: "asset-2", identifier: "desk-2", map_id: "desk-2", zone_id: zone_id, other_data: {floorsense_id: "fs-2"}},
        {id: "asset-3", identifier: "desk-3", map_id: "desk-3", zone_id: zone_id, other_data: {} of String => String},
      ].to_json)
    else
      JSON.parse([
        {
          id: "asset-1", identifier: "desk-1", map_id: "desk-1", zone_id: zone_id, next_page: "page-2",
          features: ["standing"], other_data: {floorsense_id: "fs-1", neighbourhoodID: "north"},
        },
      ].to_json)
    end
  end

  # background floor syncs
  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    extension_data : JSON::Any? = nil,
    deleted : Bool? = nil,
    asset_id : String? = nil,
    limit : Int32? = nil,
  )
    JSON.parse("[]")
  end
end

DriverSpecs.mock_driver "Floorsense::CustomBookingsSync" do
  system({
    StaffAPI: {StaffAPIMock},
  })

  # `settings` replaces all settings
  base_settings = {
    floor_mappings: {
      "plan-1": {
        building_id: "zone-building",
        level_id:    "zone-level",
      },
    },
    floorsense_lookup_key: "floorsense_id",
    meta_ext_mappings:     {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },
    meta_ext_static: {"source" => "placeos"},
    use_desk_assets: false,
  }
  settings(base_settings)

  it "should map desk metadata to floorsense desks" do
    lookup = Hash(String, Floorsense::DeskMeta).from_json exec(:placeos_desk_metadata, "zone-level", "zone-building").get.to_json

    # desk-3 has no floorsense id
    lookup.keys.sort!.should eq ["desk-1", "desk-2", "fs-1", "fs-2"]

    desk = lookup["desk-1"]
    lookup["fs-1"].place_id.should eq "desk-1"
    desk.place_id.should eq "desk-1"
    desk.floor_id.should eq "fs-1"
    desk.building.should eq "zone-building"
    desk.title.should eq "Desk 1"
    desk.ext_data.should eq({
      "floorsense_id"  => JSON::Any.new("fs-1"),
      "neighbourhood"  => JSON::Any.new("north"),
      "deskAttributes" => JSON.parse(%(["standing"])),
      "source"         => JSON::Any.new("placeos"),
    })

    # desks without features or a neighbourhood don't map them
    lookup["desk-2"].ext_data.should eq({
      "floorsense_id" => JSON::Any.new("fs-2"),
      "source"        => JSON::Any.new("placeos"),
    })
  end

  it "should map desk assets to floorsense desks" do
    settings(base_settings.merge({use_desk_assets: true}))

    lookup = Hash(String, Floorsense::DeskMeta).from_json exec(:placeos_desk_metadata, "zone-level", "zone-building").get.to_json

    # assets across both pages, asset-3 has no floorsense id
    lookup.keys.sort!.should eq ["asset-1", "asset-2", "fs-1", "fs-2"]

    desk = lookup["fs-1"]
    desk.place_id.should eq "asset-1"
    desk.floor_id.should eq "fs-1"
    desk.building.should eq "zone-building"
    desk.title.should eq "desk-1"
    desk.ext_data.should eq({
      "floorsense_id"  => JSON::Any.new("fs-1"),
      "neighbourhood"  => JSON::Any.new("north"),
      "deskAttributes" => JSON.parse(%(["standing"])),
      "source"         => JSON::Any.new("placeos"),
    })
    lookup["fs-2"].place_id.should eq "asset-2"
    lookup["fs-2"].ext_data.should eq({
      "floorsense_id" => JSON::Any.new("fs-2"),
      "source"        => JSON::Any.new("placeos"),
    })
  end

  it "should match the desk lookup key against desk fields" do
    settings(base_settings.merge({use_desk_assets: true, floorsense_lookup_key: "map_id"}))

    lookup = Hash(String, Floorsense::DeskMeta).from_json exec(:placeos_desk_metadata, "zone-level", "zone-building").get.to_json
    lookup.keys.sort!.should eq ["asset-1", "asset-2", "asset-3", "desk-1", "desk-2", "desk-3"]
    lookup["desk-3"].place_id.should eq "asset-3"
    lookup["desk-3"].ext_data["floorsense_id"].should eq JSON::Any.new("desk-3")
  end
end
