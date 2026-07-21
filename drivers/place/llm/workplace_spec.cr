require "placeos-driver/spec"
require "http/server"

# :nodoc:
# The driver fetches level maps over HTTP, so we serve a small fixture map on a
# fixed local port. Desks are laid out so the expected ordering is unambiguous
# and each geometry / transform case the parser supports is represented.
MAP_PORT = 8199

FIXTURE_MAP = <<-SVG
  <svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
    <g id="desk ids">
      <rect id="desk.1" x="0" y="0" width="10" height="10" />
      <rect id="desk.2" x="20" y="0" width="10" height="10" />
      <path id="desk.3" d="m 1,30 h 8 a 1,1 0 0 1 1,1 v 8 a 1,1 0 0 1 -1,1 h -8 a 1,1 0 0 1 -1,-1 v -8 a 1,1 0 0 1 1,-1 z" />
      <rect id="desk.4" x="0" y="0" width="10" height="10" transform="translate(100,100)" />
      <rect id="desk.5" x="0" y="0" width="10" height="10" transform="rotate(90,0,0)" />
    </g>
    <g id="room ids">
      <rect id="room.1" x="60" y="60" width="20" height="20" />
    </g>
  </svg>
  SVG

spawn do
  server = HTTP::Server.new do |context|
    context.response.content_type = "image/svg+xml"
    context.response.print FIXTURE_MAP
  end
  server.bind_tcp "127.0.0.1", MAP_PORT
  server.listen
end

# :nodoc:
# The spec harness gives the control system these zones, so the building the
# driver resolves must be one of them (we use "zone-building").
class StaffAPI < DriverSpecs::MockDriver
  ORG_ZONE = {
    id:           "zone-org",
    name:         "Acme Corp",
    display_name: "Acme",
    tags:         ["org"],
    parent_id:    nil,
    timezone:     "Australia/Sydney",
  }

  REGION_ZONE = {
    id:           "zone-region",
    name:         "Western Region",
    display_name: "WA",
    tags:         ["region"],
    parent_id:    "zone-org",
    timezone:     nil,
  }

  BUILDING_ZONE = {
    id:           "zone-building",
    name:         "Tower",
    display_name: "Perth Tower",
    tags:         ["building"],
    parent_id:    "zone-region",
    timezone:     "Australia/Perth",
  }

  LEVEL_ZONE = {
    id:           "zone-level-1",
    name:         "Level 2",
    display_name: "Level 2",
    tags:         ["level"],
    parent_id:    "zone-building",
    timezone:     nil,
    map_id:       "http://127.0.0.1:#{MAP_PORT}/level.svg",
  }

  def on_load
    self[:bookings_created] = 0
  end

  def zone(zone_id : String)
    case zone_id
    when "zone-org"      then ORG_ZONE
    when "zone-region"   then REGION_ZONE
    when "zone-building" then BUILDING_ZONE
    when "zone-level-1"  then LEVEL_ZONE
    else
      raise "unknown zone #{zone_id}"
    end
  end

  def zones(
    q : String? = nil,
    limit : Int32 = 1000,
    offset : Int32 = 0,
    parent : String? = nil,
    tags : Array(String) | String? = nil,
  )
    tag_list = case tags
               in String
                 [tags]
               in Array(String)
                 tags
               in Nil
                 [] of String
               end

    if tag_list.includes?("building")
      [BUILDING_ZONE]
    elsif tag_list.includes?("level") && parent == "zone-building"
      [LEVEL_ZONE]
    else
      [] of typeof(BUILDING_ZONE)
    end
  end

  def user(id : String? = nil)
    {
      id:     id || "spec-user",
      name:   "Spec User",
      email:  "spec@example.com",
      groups: ["staff"] of String,
    }
  end

  def metadata(id : String, key : String? = nil)
    if key == "desks" && id == "zone-level-1"
      {"desks" => {"details" => [
        {id: "desk-1", name: "Desk 1", map_id: "map-desk-1", groups: [] of String, features: ["window"]},
        {id: "desk-2", name: "Desk 2", map_id: nil, groups: [] of String, features: [] of String},
      ]}}
    else
      {} of String => JSON::Any
    end
  end

  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
  )
    [] of typeof({
      id:              0_i64,
      booking_type:    "",
      asset_id:        "",
      user_id:         "",
      user_email:      "",
      user_name:       "",
      booked_by_email: "",
      booked_by_name:  "",
      checked_in:      false,
      booking_start:   0_i64,
      booking_end:     0_i64,
      zones:           [] of String,
    })
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String) = [] of String,
    asset_name : String? = nil,
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    description : String? = nil,
    time_zone : String? = nil,
    extension_data : JSON::Any? = nil,
    utm_source : String? = nil,
  )
    self[:bookings_created] = self[:bookings_created].as_i + 1
    self[:last_booking_zones] = zones
    self[:last_booking_type] = booking_type
    self[:last_booking_asset] = asset_id
    self[:last_booking_asset_name] = asset_name || ""
    self[:last_booking_description] = description || ""
    self[:last_booking_timezone] = time_zone || ""
    self[:last_booking_start] = booking_start || 0_i64
    self[:last_booking_end] = booking_end || 0_i64
    self[:last_booking_extension] = extension_data || JSON.parse("{}")
    {id: self[:bookings_created].as_i.to_i64 + 999_i64}
  end
end

DriverSpecs.mock_driver "Place::Workplace" do
  system({
    StaffAPI: {StaffAPI},
  })

  settings({
    time_zone:          "Australia/Sydney",
    max_booking_days:   14,
    booking_start_hour: 9,
    booking_end_hour:   17,
  })

  # let on_update settle
  sleep 200.milliseconds

  perth = Time::Location.load("Australia/Perth")

  it "tags the booking with the full org/region/building/level hierarchy" do
    exec(
      :book_relative,
      booking_type: "desk",
      asset_id: "desk-1",
      level_id: "zone-level-1",
      day_offset: 1,
      number_of_days: 1,
    ).get

    zones = system(:StaffAPI)[:last_booking_zones].as_a.map(&.as_s)
    # matches the order the mobile app submits: [org, region, building, level]
    zones.should eq ["zone-org", "zone-region", "zone-building", "zone-level-1"]
  end

  it "populates asset_name, description and extension_data to match the app form" do
    exec(
      :book_relative,
      booking_type: "desk",
      asset_id: "desk-1",
      level_id: "zone-level-1",
      day_offset: 1,
      number_of_days: 1,
    ).get

    system(:StaffAPI)[:last_booking_asset_name].as_s.should eq "Desk 1"
    system(:StaffAPI)[:last_booking_description].as_s.should eq "Desk 1"

    ext = system(:StaffAPI)[:last_booking_extension].as_h
    ext["assigned_asset_id"].as_s.should eq "desk-1"
    ext["assigned_asset_name"].as_s.should eq "Desk 1"
    ext["name"].as_s.should eq "Desk 1"
    ext["map_id"].as_s.should eq "map-desk-1"
    ext["app_name"].as_s.should eq "LLM"
  end

  it "falls back to the asset_id for extension map_id when the desk has none" do
    exec(
      :book_relative,
      booking_type: "desk",
      asset_id: "desk-2",
      level_id: "zone-level-1",
      day_offset: 1,
      number_of_days: 1,
    ).get

    ext = system(:StaffAPI)[:last_booking_extension].as_h
    ext["map_id"].as_s.should eq "desk-2"
  end

  it "uses the configurable start and end hours in the building timezone" do
    exec(
      :book_relative,
      booking_type: "desk",
      asset_id: "desk-1",
      level_id: "zone-level-1",
      day_offset: 3,
      number_of_days: 1,
    ).get

    start_time = Time.unix(system(:StaffAPI)[:last_booking_start].as_i64).in(perth)
    end_time = Time.unix(system(:StaffAPI)[:last_booking_end].as_i64).in(perth)

    start_time.hour.should eq 9
    start_time.minute.should eq 0
    end_time.hour.should eq 17
    end_time.minute.should eq 0
    # booking is against the building's own timezone
    system(:StaffAPI)[:last_booking_timezone].as_s.should eq "Australia/Perth"
  end

  it "book_relative rejects bookings beyond the max window" do
    expect_raises(Exception, /more than 14 days in advance/) do
      exec(
        :book_relative,
        booking_type: "desk",
        asset_id: "desk-1",
        level_id: "zone-level-1",
        day_offset: 15,
        number_of_days: 1,
      ).get
    end
  end

  it "book_relative rejects a multi-day booking that runs past the max window" do
    expect_raises(Exception, /more than 14 days in advance/) do
      exec(
        :book_relative,
        booking_type: "desk",
        asset_id: "desk-1",
        level_id: "zone-level-1",
        day_offset: 14,
        number_of_days: 2, # furthest day is 15 days out
      ).get
    end
  end

  it "book_relative permits a booking on the last allowed day" do
    created_before = system(:StaffAPI)[:bookings_created].as_i
    exec(
      :book_relative,
      booking_type: "desk",
      asset_id: "desk-1",
      level_id: "zone-level-1",
      day_offset: 14,
      number_of_days: 1,
    ).get
    system(:StaffAPI)[:bookings_created].as_i.should eq created_before + 1
  end

  it "book_on tags the full hierarchy and honours the booking window" do
    date = Time.local(perth).at_beginning_of_day + 3.days
    exec(
      :book_on,
      booking_type: "desk",
      asset_id: "desk-1",
      level_id: "zone-level-1",
      date: date,
      number_of_days: 1,
    ).get

    zones = system(:StaffAPI)[:last_booking_zones].as_a.map(&.as_s)
    zones.should eq ["zone-org", "zone-region", "zone-building", "zone-level-1"]

    start_time = Time.unix(system(:StaffAPI)[:last_booking_start].as_i64).in(perth)
    start_time.hour.should eq 9
    start_time.to_s("%F").should eq date.to_s("%F")
  end

  it "nearby_desks orders desks by distance from the source desk" do
    # desk.1 is centred on (5,5): desk.5 is 10 away (rotated), desk.2 is 20
    # away, desk.3 is 30 away (path with arcs) and desk.4 is translated well
    # clear of the rest. The `desk ids` group that wraps them is not a desk.
    nearby = exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "desk.1").get
    Array(String).from_json(nearby.to_json).should eq ["desk.5", "desk.2", "desk.3", "desk.4"]
  end

  it "nearby_desks raises when the desk is not on the map" do
    expect_raises(Exception, /desk.404/) do
      exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "desk.404").get
    end
  end

  it "book_on rejects a date beyond the max window" do
    date = Time.local(perth).at_beginning_of_day + 20.days
    expect_raises(Exception, /more than 14 days in advance/) do
      exec(
        :book_on,
        booking_type: "desk",
        asset_id: "desk-1",
        level_id: "zone-level-1",
        date: date,
        number_of_days: 1,
      ).get
    end
  end
end
