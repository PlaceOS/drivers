require "placeos-driver/spec"
require "placeos-driver/interface/zone_access_security"

DriverSpecs.mock_driver "Place::Bookings::GrantAreaAccess" do
  system({
    StaffAPI:         {StaffAPIMock},
    Calendar:         {CalendarMock},
    LocationServices: {LocationServicesMock},
    Security:         {SecurityMock},
  })

  base_settings = {
    lookup_using_username:   false,
    security_zone_whitelist: ["group-a", "group-b"],
    request_retries:         0,
  }
  settings(base_settings)
  staff_api = system(:StaffAPI).as(StaffAPIMock)
  security = system(:Security).as(SecurityMock)

  # ===================================================
  # desk metadata
  # ===================================================
  # a single security group per desk, blocked groups are not on the whitelist
  exec(:desks, "zone-level-1").get.should eq({"desk-1" => ["group-a"]})

  exec(:ensure_booking_access).get
  staff_api.metadata_requests.should eq ["zone-level-1", "zone-level-1"]
  security.members.should eq({"group-a" => ["card-alice@org.com"]})
  status[:sync_errors].should eq [] of String
  status[:sync_blocked].should eq({"desk-2" => ["group-blocked"]})

  report = exec(:security_zone_report).get.not_nil!
  report["allocated"].should eq ["group-a"]
  report["blocked"].should eq({"desk-2" => ["group-blocked"]})
  report["in_whitelist_only"].should eq ["group-b"]

  # ===================================================
  # desk assets
  # ===================================================
  metadata_requests = staff_api.metadata_requests.size
  staff_api.use_assets
  settings(base_settings.merge({use_desk_assets: true}))

  # desks can have multiple security groups, only whitelisted groups are granted
  exec(:desks, "zone-level-1").get.should eq({
    "asset-1" => ["group-a", "group-b"],
    "asset-2" => ["group-b"],
  })
  staff_api.asset_requests.should eq [{"zone-level-1", nil}, {"zone-level-1", "page-2"}]

  # bookings reference the Asset#id, the stale metadata desk id grants nothing
  exec(:ensure_booking_access).get
  staff_api.metadata_requests.size.should eq metadata_requests
  security.members.should eq({
    "group-a" => ["card-alice@org.com"],
    "group-b" => ["card-alice@org.com", "card-bob@org.com"],
  })
  status[:sync_errors].should eq [] of String
  status[:sync_blocked].should eq({"asset-2" => ["group-blocked"]})

  report = exec(:security_zone_report).get.not_nil!
  report["allocated"].should eq ["group-a", "group-b"]
  report["blocked"].should eq({"asset-2" => ["group-blocked"]})
  report["in_whitelist_only"].should eq [] of String
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter metadata_requests : Array(String) = [] of String
  getter asset_requests : Array(Tuple(String?, String?)) = [] of Tuple(String?, String?)
  getter? assets_mode : Bool = false

  def use_assets
    @assets_mode = true
    @asset_requests.clear
  end

  def systems_in_building(zone_id : String, ids_only : Bool = true)
    {"zone-level-1" => ["sys-1"]}
  end

  def zone(zone_id : String)
    {id: zone_id, name: "Building", tags: ["building"], timezone: "Australia/Sydney"}
  end

  def metadata(id : String, key : String? = nil)
    @metadata_requests << id
    {desks: {name: "desks", details: [
      {id: "desk-1", name: "Desk 1", security: "group-a"},
      {id: "desk-2", name: "Desk 2", security: "group-blocked"},
      {id: "desk-3", name: "Desk 3"},
    ]}}
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    raise "unexpected asset type #{type_id}" unless type_id == "type-desk"
    @asset_requests << {zone_id, next_page}

    if next_page
      [
        {id: "asset-2", identifier: "desk-2", zone_id: "zone-level-1", security_system_groups: ["group-blocked", "group-b"]},
        {id: "asset-3", identifier: "desk-3", zone_id: "zone-level-1", security_system_groups: [] of String},
      ]
    else
      [{id: "asset-1", identifier: "desk-1", zone_id: "zone-level-1", security_system_groups: ["group-a", "group-b"], next_page: "page-2"}]
    end
  end

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
    prefix = assets_mode? ? "asset" : "desk"
    bookings = [
      {id: 1, asset_id: "#{prefix}-1", user_email: "Alice@org.com", booking_type: "desk"},
      {id: 2, asset_id: "#{prefix}-2", user_email: "bob@org.com", booking_type: "desk"},
      {id: 3, asset_id: "#{prefix}-3", user_email: "carl@org.com", booking_type: "desk"},
    ]
    # a booking still referencing the metadata desk id
    bookings << {id: 4, asset_id: "desk-1", user_email: "dave@org.com", booking_type: "desk"} if assets_mode?
    bookings
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_user(user_id : String)
    {id: user_id, username: user_id}
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def building_id : String
    "zone-building"
  end
end

# :nodoc:
struct MockCardHolder < PlaceOS::Driver::Interface::ZoneAccessSecurity::CardHolderDetails
  def initialize(@id, @name, @email)
  end
end

# :nodoc:
struct MockZone < PlaceOS::Driver::Interface::ZoneAccessSecurity::ZoneDetails
  def initialize(@id, @name, @description)
  end
end

# :nodoc:
class SecurityMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::ZoneAccessSecurity

  # zone id => card holder ids
  @members = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

  def members : Hash(String, Array(String))
    @members.transform_values(&.sort)
  end

  def card_holder_id_lookup(email : String) : String | Int64 | Nil
    "card-#{email}"
  end

  def card_holder_lookup(id : String | Int64) : CardHolderDetails
    MockCardHolder.new(id, id.to_s, nil)
  end

  def zone_access_id_lookup(name : String, exact_match : Bool = true) : String | Int64 | Nil
    name if name.starts_with?("group-")
  end

  def zone_access_lookup(id : String | Int64) : ZoneDetails
    MockZone.new(id, id.to_s, nil)
  end

  def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil) : String | Int64 | Nil
    card_holder_id.to_s if @members[zone_id.to_s]?.try(&.includes?(card_holder_id.to_s))
  end

  def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    @members[zone_id.to_s] << card_holder_id.to_s
    true
  end

  def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    @members[zone_id.to_s].delete(card_holder_id.to_s)
    true
  end
end
