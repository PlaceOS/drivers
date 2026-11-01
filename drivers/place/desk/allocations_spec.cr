require "placeos-driver/spec"
require "http/server"

# :nodoc:
# serves the remote desk allocation CSV, the desk ids depend on the desk source
ALLOCATIONS_SERVER = HTTP::Server.new do |context|
  prefix = context.request.path == "/assets.csv" ? "asset" : "desk"
  context.response.content_type = "text/csv"
  context.response.print <<-CSV
    "PlaceOS ID","Name","Assigned To","desk Type"
    "#{prefix}-1","Desk 1 new","Alice@org.com","Staff"
    "#{prefix}-2","Desk 2","bob@org.com","Staff"
    "unknown-desk","Unknown","carl@org.com","Staff"
    CSV
end
ALLOCATIONS_PORT = ALLOCATIONS_SERVER.bind_unused_port("127.0.0.1").port
spawn { ALLOCATIONS_SERVER.listen }

DriverSpecs.mock_driver "Place::Desk::Allocations" do
  system({
    StaffAPI: {StaffAPIMock},
    Calendar: {CalendarMock},
  })

  base_settings = {
    allocation_list_url: "http://127.0.0.1:#{ALLOCATIONS_PORT}/metadata.csv",
    polling_cron:        "0 0 1 1 *",
  }
  settings(base_settings)
  staff_api = system(:StaffAPI).as(StaffAPIMock)

  # ===================================================
  # desk metadata
  # ===================================================
  desks = exec(:desks).get.not_nil!.as_h
  desks.keys.should eq ["desk-1", "desk-2", "desk-3", "desk-4"]
  desks["desk-1"]["features"].should eq "HDR"
  desks["desk-2"]["allocation_email"].should eq "bob@org.com"
  desks["desk-2"]["bookable"].should eq false
  desks["desk-3"]["level_code"].should eq "L1"
  desks["desk-3"]["building_code"].should eq "BLD"

  csv = exec(:get_desks, "GET", {} of String => Array(String), "").get.not_nil!.as_a
  csv[0].should eq 200
  csv[2].as_s.split("\n").reject(&.empty?).should eq [
    "desk_id,desk_name,building,level,allocation_email,desk_type",
    "desk-1,Desk 1,BLD,L1,,Student Hot Desk",
    "desk-2,Desk 2,BLD,L1,bob@org.com,Staff",
    "desk-3,Desk 3,BLD,L1,student.jane@org.com,Student",
    "desk-4,Desk 4,BLD,L1,,Staff",
  ]

  # desk-1 is newly allocated, desk-3 is no longer allocated
  exec(:pull_allocations, false).get
  staff_api.updated_assets.should be_empty
  staff_api.metadata_writes.size.should eq 1
  level, written = staff_api.metadata_writes.first
  level.should eq "zone-level-1"
  written.as_a.map(&.as_h).should eq [
    {"id" => "desk-1", "name" => "Desk 1 new", "bookable" => true, "features" => ["HDR"], "assigned_to" => "alice@org.com", "assigned_name" => "Alice Smith"},
    {"id" => "desk-2", "name" => "Desk 2", "bookable" => false, "features" => [] of String, "assigned_to" => "Bob@org.com", "assigned_name" => "Bob"},
    {"id" => "desk-3", "name" => "Desk 3", "bookable" => false, "features" => [] of String, "assigned_to" => nil, "assigned_name" => ""},
    {"id" => "desk-4", "name" => "Desk 4", "bookable" => false, "features" => [] of String},
  ].map { |desk| JSON.parse(desk.to_json).as_h }

  # desk-2 booking is correct, desk-3 is missing a booking, desk-old and asset-2 are dangling
  exec(:sync_allocations, false).get
  staff_api.deleted.should eq [2_i64, 3_i64]
  staff_api.created.should eq [{"desk-3", "student.jane@org.com", ["zone-org", "zone-building", "zone-level-1"]}]

  # ===================================================
  # desk assets
  # ===================================================
  staff_api.reset
  settings(base_settings.merge({
    allocation_list_url: "http://127.0.0.1:#{ALLOCATIONS_PORT}/assets.csv",
    use_desk_assets:     true,
  }))

  desks = exec(:desks).get.not_nil!.as_h
  desks.keys.should eq ["asset-1", "asset-2", "asset-3", "asset-4"]
  desks["asset-1"]["name"].should eq "Desk 1"
  desks["asset-2"]["allocation_email"].should eq "bob@org.com"
  staff_api.asset_requests.should eq [{"zone-level-1", nil}, {"zone-level-1", "page-2"}]

  csv = exec(:get_desks, "GET", {} of String => Array(String), "").get.not_nil!.as_a
  csv[2].as_s.split("\n").reject(&.empty?).should eq [
    "desk_id,desk_name,building,level,allocation_email,desk_type",
    "asset-1,Desk 1,BLD,L1,,Student Hot Desk",
    "asset-2,Desk 2,BLD,L1,bob@org.com,Staff",
    "asset-3,Desk 3,BLD,L1,student.jane@org.com,Student",
    "asset-4,Desk 4,BLD,L1,,Staff",
  ]

  # changes are written to each desk asset, not the metadata
  exec(:pull_allocations, false).get
  staff_api.metadata_writes.should be_empty
  staff_api.updated_assets.should eq [
    {"asset-1", JSON.parse({identifier: "Desk 1 new", assigned_to: "alice@org.com", assigned_name: "Alice Smith", bookable: true}.to_json)},
    {"asset-3", JSON.parse({identifier: "Desk 3", assigned_to: nil, assigned_name: "", bookable: false}.to_json)},
  ]

  # bookings reference the Asset#id, the legacy desk id bookings are dangling
  exec(:sync_allocations, false).get
  staff_api.deleted.should eq [1_i64, 2_i64]
  staff_api.created.should eq [{"asset-3", "student.jane@org.com", ["zone-org", "zone-building", "zone-level-1"]}]
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter metadata_writes = [] of Tuple(String, JSON::Any)
  getter updated_assets = [] of Tuple(String, JSON::Any)
  getter asset_requests = [] of Tuple(String?, String?)
  getter deleted = [] of Int64
  getter created = [] of Tuple(String, String, Array(String))

  def reset
    @metadata_writes.clear
    @updated_assets.clear
    @asset_requests.clear
    @deleted.clear
    @created.clear
  end

  DESKS = [
    {id: "desk-1", name: "Desk 1", bookable: true, features: ["HDR"]},
    {id: "desk-2", name: "Desk 2", bookable: false, features: [] of String, assigned_to: "Bob@org.com", assigned_name: "Bob"},
    {id: "desk-3", name: "Desk 3", bookable: true, features: [] of String, assigned_to: "student.jane@org.com"},
    {id: "desk-4", name: "Desk 4", bookable: false, features: [] of String},
  ]

  def zones(q : String? = nil, limit : Int32 = 1000, offset : Int32 = 0, parent : String? = nil, tags : Array(String) | String? = nil)
    if tags.to_s.includes?("building")
      [{id: "zone-building", name: "Building", tags: ["building"], code: "BLD", timezone: "Australia/Sydney", parent_id: "zone-org"}]
    else
      [{id: "zone-level-1", name: "Level 1", tags: ["level"], code: "L1", parent_id: "zone-building"}]
    end
  end

  def zone(zone_id : String)
    {id: zone_id, name: "Org", tags: ["org"]}
  end

  def metadata(id : String, key : String? = nil)
    {desks: {name: "desks", details: DESKS}}
  end

  def metadata_children(id : String, key : String? = nil)
    [{zone: {id: "zone-level-1"}, metadata: {desks: {name: "desks", details: DESKS}}}]
  end

  def write_metadata(id : String, key : String, payload : JSON::Any, description : String = "")
    @metadata_writes << {id, payload}
    payload
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    raise "unexpected asset type #{type_id}" unless type_id == "type-desk"
    @asset_requests << {zone_id, next_page} if zone_id

    assets = DESKS.map_with_index do |desk, index|
      {
        id:            "asset-#{index + 1}",
        identifier:    desk[:name],
        zone_id:       "zone-level-1",
        bookable:      desk[:bookable],
        features:      desk[:features],
        assigned_to:   desk[:assigned_to]?,
        assigned_name: desk[:assigned_name]?,
        next_page:     index.zero? ? "page-2" : nil,
      }
    end
    next_page ? assets[2..] : assets[0..1]
  end

  def update_asset(id : String, asset : JSON::Any)
    @updated_assets << {id, asset}
    asset
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
    [
      {id: 1, asset_id: "desk-2", user_email: "bob@org.com", booking_type: "desk", recurrence_type: "daily"},
      {id: 2, asset_id: "desk-old", user_email: "old@org.com", booking_type: "desk", recurrence_type: "daily"},
      {id: 3, asset_id: "asset-2", user_email: "bob@org.com", booking_type: "desk", recurrence_type: "daily"},
      # not an allocation booking
      {id: 4, asset_id: "desk-other", user_email: "x@org.com", booking_type: "desk", recurrence_type: "none"},
    ]
  end

  def booking_delete(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    @deleted << booking_id.to_i64
    true
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    checked_in : Bool = false,
    approved : Bool? = nil,
    title : String? = nil,
    description : String? = nil,
    time_zone : String? = nil,
    extension_data : JSON::Any? = nil,
    utm_source : String? = nil,
    limit_override : Int64? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    attendees : Array(JSON::Any)? = nil,
    process_state : String? = nil,
    recurrence_type : String? = nil,
    recurrence_days : Int32? = nil,
    recurrence_nth_of_month : Int32? = nil,
    recurrence_interval : Int32? = nil,
    recurrence_end : Int64? = nil,
    asset_ids : Array(String)? = nil,
    asset_name : String? = nil,
  )
    @created << {asset_id, user_email, zones}
    {id: 10}
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_user(user_id : String, additional_fields : Array(String)? = nil)
    {name: "Alice Smith", email: user_id}
  end
end
