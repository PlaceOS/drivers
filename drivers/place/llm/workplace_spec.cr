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

# :nodoc:
# A second level used for the colleague proximity ranking. Three colleagues sit
# at c1 (0,0), c2 (100,0) and c3 (100,100). Of the two free desks, `a` (10,0) is
# by far the closest to c1 but is the furthest from the other two, while `b`
# (55,50) is a reasonable walk for everyone. A Borda count ranks `b` first.
COLLEAGUE_MAP = <<-SVG
  <svg viewBox="-50 -50 250 250" xmlns="http://www.w3.org/2000/svg">
    <g id="desk ids">
      <rect id="desk.c1" x="-5" y="-5" width="10" height="10" />
      <rect id="desk.c2" x="95" y="-5" width="10" height="10" />
      <rect id="desk.c3" x="95" y="95" width="10" height="10" />
      <rect id="desk.a" x="5" y="-5" width="10" height="10" />
      <rect id="desk.b" x="50" y="45" width="10" height="10" />
    </g>
  </svg>
  SVG

spawn do
  server = HTTP::Server.new do |context|
    context.response.content_type = "image/svg+xml"
    context.response.print(context.request.path == "/colleagues.svg" ? COLLEAGUE_MAP : FIXTURE_MAP)
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

  LEVEL_ZONE_2 = {
    id:           "zone-level-2",
    name:         "Level 3",
    display_name: "Level 3",
    tags:         ["level"],
    parent_id:    "zone-building",
    timezone:     nil,
    map_id:       "http://127.0.0.1:#{MAP_PORT}/colleagues.svg",
  }

  # email => the desk they have booked. Note the booked asset_id and the id the
  # desk is drawn under on the map deliberately differ.
  COLLEAGUE_DESKS = {
    "c1@example.com" => {"L2-C1", "zone-level-2"},
    "c2@example.com" => {"L2-C2", "zone-level-2"},
    "c3@example.com" => {"L2-C3", "zone-level-2"},
    "c4@example.com" => {"L1-A", "zone-level-1"},
  }

  CONTACTS = [
    {name: "Colleague One", email: "c1@example.com", groups: ["staff", "eng"]},
    {name: "Colleague Two", email: "c2@example.com", groups: ["staff"]},
    {name: "Colleague Three", email: "c3@example.com", groups: ["design"]},
    {name: "Colleague Four", email: "c4@example.com", groups: ["staff"]},
    # working from home, so has no desk booked
    {name: "Colleague Five", email: "c5@example.com", groups: ["staff"]},
  ]

  def on_load
    self[:bookings_created] = 0
  end

  def zone(zone_id : String)
    case zone_id
    when "zone-org"      then ORG_ZONE
    when "zone-region"   then REGION_ZONE
    when "zone-building" then BUILDING_ZONE
    when "zone-level-1"  then LEVEL_ZONE
    when "zone-level-2"  then LEVEL_ZONE_2
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
      [LEVEL_ZONE, LEVEL_ZONE_2]
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
    # every user has the same contact list in this spec
    return {"contacts" => {"details" => CONTACTS}} if key == "contacts"

    case {key, id}
    when {"desks", "zone-level-1"}
      {"desks" => {"details" => [
        {id: "desk-1", name: "Desk 1", map_id: "map-desk-1", groups: [] of String, features: ["window"]},
        {id: "desk-2", name: "Desk 2", map_id: nil, groups: [] of String, features: [] of String},
        {id: "L1-A", name: "Level 1 A", map_id: "desk.1", groups: [] of String, features: [] of String},
        {id: "L1-B", name: "Level 1 B", map_id: "desk.5", groups: [] of String, features: [] of String},
        {id: "L1-C", name: "Level 1 C", map_id: "desk.2", groups: [] of String, features: [] of String},
        {id: "L1-D", name: "Level 1 D", map_id: "desk.3", groups: [] of String, features: [] of String},
        {id: "L1-E", name: "Level 1 E", map_id: "desk.4", groups: [] of String, features: [] of String},
      ]}}
    when {"desks", "zone-level-2"}
      {"desks" => {"details" => [
        {id: "L2-C1", name: "Level 2 C1", map_id: "desk.c1", groups: [] of String, features: [] of String},
        {id: "L2-C2", name: "Level 2 C2", map_id: "desk.c2", groups: [] of String, features: [] of String},
        {id: "L2-C3", name: "Level 2 C3", map_id: "desk.c3", groups: [] of String, features: [] of String},
        {id: "L2-A", name: "Level 2 A", map_id: "desk.a", groups: [] of String, features: [] of String},
        {id: "L2-B", name: "Level 2 B", map_id: "desk.b", groups: [] of String, features: [] of String},
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
    bookings = [] of JSON::Any

    if email
      # a colleague's desk for the day
      if desk = COLLEAGUE_DESKS[email]?
        asset_id, level_id = desk
        bookings << colleague_booking(asset_id, level_id, email)
      end
    elsif !zones.empty?
      # everything booked on the level, used to work out what is still free
      COLLEAGUE_DESKS.each do |colleague_email, (asset_id, level_id)|
        next unless zones.includes?(level_id)
        bookings << colleague_booking(asset_id, level_id, colleague_email)
      end
    end

    bookings
  end

  protected def colleague_booking(asset_id : String, level_id : String, email : String) : JSON::Any
    JSON.parse({
      id:             1_i64,
      booking_type:   "desk",
      asset_id:       asset_id,
      user_email:     email,
      description:    asset_id,
      zones:          ["zone-org", "zone-building", level_id],
      extension_data: {name: "#{asset_id} desk"},
    }.to_json)
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
    # L1-A is drawn as desk.1, centred on (5,5). desk.5 (L1-B) is 10 away
    # (rotated), desk.2 (L1-C) is 20 away, desk.3 (L1-D) is 30 away (path with
    # arcs) and desk.4 (L1-E) is translated well clear of the rest. The
    # `desk ids` group that wraps them is not a desk.
    nearby = exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "L1-A").get
    Array(String).from_json(nearby.to_json).should eq ["L1-B", "L1-C", "L1-D", "L1-E"]
  end

  it "nearby_desks rejects a map_id, it takes the desk_id a booking is made against" do
    # desk.1 is the id L1-A is drawn under on the map, not a bookable desk id
    expect_raises(Exception, /could not find a desk with id 'desk.1'/) do
      exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "desk.1").get
    end
  end

  it "nearby_desks raises when the desk is not configured on the level" do
    expect_raises(Exception, /desk.404/) do
      exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "desk.404").get
    end
  end

  it "nearby_desks raises when a configured desk is not drawn on the map" do
    # desk-1 is bookable but its map_id "map-desk-1" isn't in the SVG
    expect_raises(Exception, /could not find 'map-desk-1' on the level map/) do
      exec(:nearby_desks, desk_level_id: "zone-level-1", desk_id: "desk-1").get
    end
  end

  it "desks_near_colleagues ranks levels by headcount and desks by a weighted proximity" do
    result = exec(:desks_near_colleagues, day_offset: 0).get.as_a

    # level 2 has three colleagues, level 1 has one, and the colleague who is
    # working from home is not counted anywhere
    result.map(&.["level_id"].as_s).should eq ["zone-level-2", "zone-level-1"]
    result.map(&.["colleagues"].as_a.size).should eq [3, 1]
    result.map(&.["level_name"].as_s).should eq ["Level 3", "Level 2"]

    # who is sitting there, not just how many
    result.first["colleagues"].as_a.map(&.["email"].as_s).sort.should eq [
      "c1@example.com", "c2@example.com", "c3@example.com",
    ]
    result.last["colleagues"].as_a.map(&.["name"].as_s).should eq ["Colleague Four"]

    level_2 = result.first
    level_2["groups"].as_a.map(&.as_s).sort.should eq ["design", "eng", "staff"]

    # desk.a is the closest desk to one colleague but the furthest from the
    # other two, so the more central desk.b outranks it. Both are returned as
    # bookable asset ids, not the ids they are drawn under on the map.
    # Occupied desks (L2-C1..C3) are never suggested.
    level_2["nearby_desks"].as_a.map(&.as_s).should eq ["L2-B", "L2-A"]

    # L1-A is taken by the one colleague on level 1, and desk-1 / desk-2 are not
    # drawn on the map, leaving the rest ranked by distance from L1-A
    result.last["nearby_desks"].as_a.map(&.as_s).should eq ["L1-B", "L1-C", "L1-D", "L1-E"]
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
