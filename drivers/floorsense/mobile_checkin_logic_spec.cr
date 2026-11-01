require "placeos-driver/spec"

DriverSpecs.mock_driver "Floorsense::MobileCheckinLogic" do
  system({
    FloorsenseBookingSync: {FloorsenseBookingSyncMock},
    StaffAPI:              {StaffAPIMock},
  })

  # `settings` replaces all settings
  base_settings = {
    time_zone:         "Australia/Sydney",
    booking_period:    120,
    meta_ext_mappings: {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },
    use_desk_assets: false,
  }

  # desk metadata
  settings(base_settings)

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("checked-in")

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("adhoc")

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("forbidden")

  # desk assets, bookings reference the Asset#id
  settings(base_settings.merge({use_desk_assets: true}))

  resp = exec(:eui64_scanned, "euid-asset", "test-user").get
  resp.should eq("checked-in")

  # desk found on the second page of assets
  resp = exec(:eui64_scanned, "euid-asset", "test-user").get
  resp.should eq("adhoc")
  system(:StaffAPI_1)[:created].should eq({
    "asset_id"       => "asset-1",
    "title"          => "Asset Desk",
    "extension_data" => {"deskAttributes" => ["standing"], "neighbourhood" => "north"},
  })

  resp = exec(:eui64_scanned, "euid-asset", "test-user").get
  resp.should eq("forbidden")

  # desk asset is not bookable
  resp = exec(:eui64_scanned, "euid-locked", "test-user").get
  resp.should eq("forbidden")
end

# :nodoc:
class FloorsenseBookingSyncMock < DriverSpecs::MockDriver
  def eui64_to_desk_id(id : String)
    desk_id = case id
              when "euid-asset"  then "asset-1"
              when "euid-locked" then "asset-2"
              else                    "place_desk"
              end
    {level: "level_zone", desk_id: desk_id, building_id: "building_zone"}
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @query_count : Int32 = 0

  def query_bookings(type : String, zones : Array(String))
    @query_count += 1
    case @query_count
    when 1
      [{id: 1234, asset_id: "place_desk", user_id: "test-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix}]
    when 3
      # desk owned by a different user
      [{id: 1234, asset_id: "place_desk", user_id: "other-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix}]
    when 4
      [{id: 1234, asset_id: "asset-1", user_id: "test-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix}]
    when 6
      # the legacy desk id no longer matches
      [
        {id: 1234, asset_id: "place_desk", user_id: "test-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix},
        {id: 1234, asset_id: "asset-1", user_id: "other-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix},
      ]
    else
      [] of Nil
    end
  end

  def booking_check_in(booking_id : String | Int64, check_in : Bool)
    raise "wrong booking_id #{booking_id} or check_in state #{check_in}" unless booking_id == 1234 && check_in
    true
  end

  def metadata(zone_id : String, asset_type : String)
    {
      desks: {
        details: [{id: "place_desk", name: "Cool Desk", features: ["standing"]}],
      },
    }
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
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
    return [] of Nil unless type_id == "type-desk" && zone_id == "level_zone"

    if next_page == "page-2"
      JSON.parse([
        {
          id: "asset-1", identifier: "Asset Desk", zone_id: zone_id,
          features: ["standing"], other_data: {neighbourhoodID: "north"},
        },
      ].to_json)
    else
      JSON.parse([
        {id: "asset-2", identifier: "Locked Desk", zone_id: zone_id, bookable: false, next_page: "page-2"},
      ].to_json)
    end
  end

  def user(user_id : String)
    raise "unexpected user #{user_id}" unless user_id == "test-user"
    {
      id:    "test-user",
      email: "email@org.com",
      name:  "Bob Jane",
    }
  end

  def update_booking(booking_id : String | Int64, booking_end : Int64, checked_in : Bool)
    true
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64,
    booking_end : Int64,
    checked_in : Bool,
    title : String,
    approved : Bool,
    time_zone : String,
    extension_data : Hash(String, JSON::Any),
  )
    raise "bad data" unless user_id == "test-user" && asset_id.in?("place_desk", "asset-1")
    if asset_id == "place_desk"
      raise "bad data2" unless checked_in && title == "Cool Desk" && extension_data["deskAttributes"].as_a.map(&.as_s) == ["standing"]
    end
    self[:created] = {asset_id: asset_id, title: title, extension_data: extension_data}
    true
  end
end
