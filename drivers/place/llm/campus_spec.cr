require "placeos-driver/spec"
require "http/server"

# :nodoc:
# The driver fetches level maps over HTTP, so we serve fixture maps on a fixed
# local port.
MAP_PORT = 8299

# Three colleagues sit at c1 (0,0), c2 (100,0) and c3 (100,100). Of the two
# free desks, `a` (10,0) is by far the closest to c1 but the furthest from the
# other two, while `b` (55,50) is a reasonable walk for everyone - a Borda count
# ranks `b` first. `x` is drawn but restricted to a group the user isn't in.
MAP_A1 = <<-SVG
  <svg viewBox="-50 -50 350 350" xmlns="http://www.w3.org/2000/svg">
    <g id="desk ids">
      <rect id="desk.c1" x="-5" y="-5" width="10" height="10" />
      <rect id="desk.c2" x="95" y="-5" width="10" height="10" />
      <rect id="desk.c3" x="95" y="95" width="10" height="10" />
      <rect id="desk.a" x="5" y="-5" width="10" height="10" />
      <rect id="desk.b" x="50" y="45" width="10" height="10" />
      <rect id="desk.x" x="195" y="195" width="10" height="10" />
    </g>
  </svg>
  SVG

# a second building, to prove levels are ranked independently per building
MAP_B1 = <<-SVG
  <svg viewBox="-50 -50 200 200" xmlns="http://www.w3.org/2000/svg">
    <g id="desk ids">
      <rect id="desk.c4" x="-5" y="-5" width="10" height="10" />
      <rect id="desk.b1" x="5" y="-5" width="10" height="10" />
    </g>
  </svg>
  SVG

spawn do
  server = HTTP::Server.new do |context|
    context.response.content_type = "image/svg+xml"
    context.response.print(context.request.path == "/b1.svg" ? MAP_B1 : MAP_A1)
  end
  server.bind_tcp "127.0.0.1", MAP_PORT
  server.listen
end

# :nodoc:
class StaffAPI < DriverSpecs::MockDriver
  ORG_ZONE = {
    id:           "zone-org",
    name:         "Acme Corp",
    display_name: "Acme",
    location:     "",
    tags:         ["org"],
    parent_id:    nil,
    timezone:     "Australia/Sydney",
  }

  BUILDING_A = {
    id:           "zone-building-a",
    name:         "Tower A",
    display_name: "Sydney Tower",
    location:     "",
    tags:         ["building"],
    parent_id:    "zone-org",
    timezone:     "Australia/Sydney",
  }

  BUILDING_B = {
    id:           "zone-building-b",
    name:         "Tower B",
    display_name: nil,
    location:     "",
    tags:         ["building"],
    parent_id:    "zone-org",
    timezone:     "America/New_York",
  }

  LEVEL_A1 = {
    id:           "zone-level-a1",
    name:         "Level 1",
    display_name: "Ground Floor",
    location:     "",
    tags:         ["level"],
    parent_id:    "zone-building-a",
    timezone:     nil,
    map_id:       "http://127.0.0.1:#{MAP_PORT}/a1.svg",
  }

  LEVEL_A2 = {
    id:           "zone-level-a2",
    name:         "Level 2",
    display_name: nil,
    location:     "",
    tags:         ["level"],
    parent_id:    "zone-building-a",
    timezone:     nil,
  }

  LEVEL_B1 = {
    id:           "zone-level-b1",
    name:         "Floor 1",
    display_name: "Lobby",
    location:     "",
    tags:         ["level"],
    parent_id:    "zone-building-b",
    timezone:     nil,
    map_id:       "http://127.0.0.1:#{MAP_PORT}/b1.svg",
  }

  # email => {desk asset_id, level_id, building_id}. Note the booked asset_id
  # and the id the desk is drawn under on the map deliberately differ.
  COLLEAGUE_DESKS = {
    "c1@example.com" => {"desk-a1-c1", "zone-level-a1", "zone-building-a"},
    "c2@example.com" => {"desk-a1-c2", "zone-level-a1", "zone-building-a"},
    "c3@example.com" => {"desk-a1-c3", "zone-level-a1", "zone-building-a"},
    "c4@example.com" => {"desk-b1-c4", "zone-level-b1", "zone-building-b"},
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
    self[:last_booking_zones] = [] of String
    self[:last_booking_type] = ""
    self[:bookings_deleted] = [] of Int64
    self[:armed_existing_desk] = false
  end

  # spec-only hook: arm/disarm the mock so query_bookings returns an existing
  # desk booking. Default off so create-booking tests don't trip the conflict
  # check; armed for the my_bookings test and the conflict-rejection test.
  def arm_existing_desk_booking(value : Bool) : Bool
    self[:armed_existing_desk] = value
    value
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

    if tag_list.includes?("org")
      [ORG_ZONE]
    elsif tag_list.includes?("building")
      # the driver looks buildings up org-wide, without specifying a parent
      [BUILDING_A, BUILDING_B]
    elsif tag_list.includes?("level") && parent == "zone-building-a"
      [LEVEL_A1, LEVEL_A2]
    elsif tag_list.includes?("level") && parent == "zone-building-b"
      [LEVEL_B1]
    else
      [] of typeof(ORG_ZONE)
    end
  end

  def zone(zone_id : String)
    case zone_id
    when "zone-org"        then ORG_ZONE
    when "zone-building-a" then BUILDING_A
    when "zone-building-b" then BUILDING_B
    when "zone-level-a1"   then LEVEL_A1
    when "zone-level-a2"   then LEVEL_A2
    when "zone-level-b1"   then LEVEL_B1
    else
      raise "unknown zone #{zone_id}"
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

    if key == "desks"
      desks = case id
              when "zone-level-a1"
                [
                  {id: "desk-a1-01", map_id: "desk.a", groups: [] of String, features: ["window"]},
                  {id: "desk-a1-02", map_id: "desk.b", groups: [] of String, features: [] of String},
                  {id: "desk-a1-03", map_id: "desk.x", groups: ["execs"], features: [] of String},
                  {id: "desk-a1-c1", map_id: "desk.c1", groups: [] of String, features: [] of String},
                  {id: "desk-a1-c2", map_id: "desk.c2", groups: [] of String, features: [] of String},
                  {id: "desk-a1-c3", map_id: "desk.c3", groups: [] of String, features: [] of String},
                ]
              when "zone-level-a2"
                [
                  {id: "desk-a2-01", map_id: nil, groups: [] of String, features: [] of String},
                ]
              when "zone-level-b1"
                [
                  {id: "desk-b1-01", map_id: "desk.b1", groups: [] of String, features: ["standing"]},
                  {id: "desk-b1-c4", map_id: "desk.c4", groups: [] of String, features: [] of String},
                ]
              else
                nil
              end

      if desks
        {"desks" => {"details" => desks}}
      else
        {} of String => JSON::Any
      end
    else
      {} of String => JSON::Any
    end
  end

  def systems(
    q : String? = nil,
    zone_id : String? = nil,
    capacity : Int32? = nil,
    bookable : Bool? = nil,
    features : String? = nil,
    limit : Int32 = 1000,
    offset : Int32 = 0,
  )
    rooms = [
      {
        id:           "sys-room-a1",
        name:         "Room A1",
        display_name: "Boardroom",
        features:     ["video"],
        email:        "room-a1@acme.com",
        capacity:     8,
        map_id:       "map-a1",
        zones:        ["zone-building-a", "zone-level-a1"],
      },
      {
        id:           "sys-room-a2",
        name:         "Room A2",
        display_name: "Huddle",
        features:     [] of String,
        email:        "room-a2@acme.com",
        capacity:     4,
        map_id:       nil,
        zones:        ["zone-building-a", "zone-level-a2"],
      },
      {
        id:           "sys-room-b1",
        name:         "Room B1",
        display_name: "NY Boardroom",
        features:     ["video"],
        email:        "room-b1@acme.com",
        capacity:     10,
        map_id:       nil,
        zones:        ["zone-building-b", "zone-level-b1"],
      },
    ]

    rooms.select do |r|
      next false if capacity && r[:capacity] < capacity
      next true if zone_id.nil?
      r[:zones].includes?(zone_id)
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
    self[:last_query_zones] = zones
    self[:last_query_type] = type || ""

    # return an existing desk booking only when the spec has explicitly armed
    # it via arm_existing_desk_booking, so the regular create-booking tests
    # don't accidentally trip the conflict check.
    armed = self[:armed_existing_desk]?.try(&.as_bool) || false
    if type == "desk" && zones.includes?("zone-org") && armed
      return [
        {
          id:              500_i64,
          booking_type:    "desk",
          asset_id:        "desk-a1-02",
          user_id:         "spec-user-id",
          user_email:      "spec@example.com",
          user_name:       "Spec User",
          booked_by_email: "spec@example.com",
          booked_by_name:  "Spec User",
          checked_in:      false,
          booking_start:   period_start || 0_i64,
          booking_end:     period_end || 0_i64,
          zones:           ["zone-level-a1", "zone-building-a", "zone-org"],
        },
      ]
    end

    bookings = [] of JSON::Any

    if email
      # a colleague's desk for the day
      if desk = COLLEAGUE_DESKS[email]?
        asset_id, level_id, building_id = desk
        bookings << colleague_booking(asset_id, level_id, building_id, email)
      end
    elsif !zones.empty?
      # everything booked on the level, used to work out what is still free
      COLLEAGUE_DESKS.each do |colleague_email, (asset_id, level_id, building_id)|
        next unless zones.includes?(level_id)
        bookings << colleague_booking(asset_id, level_id, building_id, colleague_email)
      end
    end

    bookings
  end

  protected def colleague_booking(asset_id : String, level_id : String, building_id : String, email : String) : JSON::Any
    JSON.parse({
      id:              1_i64,
      booking_type:    "desk",
      asset_id:        asset_id,
      user_id:         nil,
      user_email:      email,
      user_name:       email,
      booked_by_email: email,
      booked_by_name:  email,
      checked_in:      false,
      booking_start:   0_i64,
      booking_end:     0_i64,
      description:     asset_id,
      zones:           ["zone-org", building_id, level_id],
      extension_data:  {name: "#{asset_id} desk"},
    }.to_json)
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String? = nil,
    user_email : String? = nil,
    user_name : String? = nil,
    zones : Array(String) = [] of String,
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
    asset_name : String? = nil,
  )
    self[:bookings_created] = self[:bookings_created].as_i + 1
    self[:last_booking_zones] = zones
    self[:last_booking_type] = booking_type
    self[:last_booking_asset] = asset_id
    self[:last_booking_asset_name] = asset_name || ""
    self[:last_booking_description] = description || ""
    self[:last_booking_extension] = extension_data || JSON.parse("{}")
    self[:last_booking_timezone] = time_zone || ""
    self[:last_booking_start] = booking_start || 0_i64
    self[:last_booking_end] = booking_end || 0_i64
    {id: self[:bookings_created].as_i.to_i64 + 999_i64}
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    {
      id:              booking_id.to_s.to_i64,
      booking_type:    "desk",
      asset_id:        "desk-a1-02",
      user_id:         "spec-user-id",
      user_email:      "spec@example.com",
      user_name:       "Spec User",
      booked_by_email: "spec@example.com",
      booked_by_name:  "Spec User",
      zones:           ["zone-level-a1", "zone-building-a", "zone-org"],
    }
  end

  def booking_delete(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    deleted = self[:bookings_deleted].as_a.map(&.as_i64)
    deleted << booking_id.to_s.to_i64
    self[:bookings_deleted] = deleted
    nil
  end
end

DriverSpecs.mock_driver "Place::Campus" do
  system({
    StaffAPI: {StaffAPI},
  })

  # allow on_update to settle
  sleep 200.milliseconds

  it "lists buildings in the org" do
    buildings = exec(:buildings).get.as_a
    buildings.size.should eq 2

    ids = buildings.map(&.["building_id"].as_s)
    ids.should contain "zone-building-a"
    ids.should contain "zone-building-b"

    # display_name preferred, falling back to name
    names = buildings.map(&.["name"].as_s)
    names.should contain "Sydney Tower" # display_name set
    names.should contain "Tower B"      # display_name nil → falls back to name
  end

  it "lists levels for a given building only" do
    levels = exec(:levels, building_id: "zone-building-a").get.as_a
    level_ids = levels.map(&.["id"].as_s)
    # includes the building zone itself plus its levels (existing behaviour)
    level_ids.should contain "zone-building-a"
    level_ids.should contain "zone-level-a1"
    level_ids.should contain "zone-level-a2"
    level_ids.should_not contain "zone-level-b1"

    # desk metadata is populated for levels that have desks
    level_a1 = levels.find! { |l| l["id"].as_s == "zone-level-a1" }
    level_a1["bookable_desk_count"].as_i.should eq 6
    level_a1["desk_features"].as_a.map(&.as_s).should contain "window"
  end

  it "raises when given an unknown building_id" do
    expect_raises(Exception, /could not find building_id/) do
      exec(:levels, building_id: "zone-bogus").get
    end
  end

  it "lists meeting rooms scoped to the requested building" do
    rooms = exec(:meeting_rooms, building_id: "zone-building-a").get.as_a
    room_ids = rooms.map(&.["id"].as_s)
    room_ids.should contain "sys-room-a1"
    room_ids.should contain "sys-room-a2"
    room_ids.should_not contain "sys-room-b1"

    boardroom = rooms.find! { |r| r["id"].as_s == "sys-room-a1" }
    boardroom["building_id"].as_s.should eq "zone-building-a"
    boardroom["building_name"].as_s.should eq "Sydney Tower"
    boardroom["level_id"].as_s.should eq "zone-level-a1"
    boardroom["level_name"].as_s.should eq "Ground Floor"
  end

  it "filters meeting rooms by minimum capacity" do
    rooms = exec(:meeting_rooms, building_id: "zone-building-a", minimum_capacity: 6).get.as_a
    rooms.size.should eq 1
    rooms.first["id"].as_s.should eq "sys-room-a1"
  end

  it "my_bookings queries with the org id as the zone filter" do
    system(:StaffAPI).as(StaffAPI).arm_existing_desk_booking(true)
    begin
      bookings = exec(:my_bookings).get.as_a
      system(:StaffAPI)[:last_query_zones].as_a.map(&.as_s).should eq ["zone-org"]

      bookings.size.should be > 0
      booking = bookings.first
      booking["building_id"].as_s.should eq "zone-building-a"
      booking["building_name"].as_s.should eq "Sydney Tower"
      booking["level_id"].as_s.should eq "zone-level-a1"
      booking["asset_id"].as_s.should eq "desk-a1-02"
    ensure
      system(:StaffAPI).as(StaffAPI).arm_existing_desk_booking(false)
    end
  end

  it "book_relative writes level, building and org into the booking zones" do
    created_before = system(:StaffAPI)[:bookings_created].as_i

    result = exec(
      :book_relative,
      building_id: "zone-building-a",
      booking_type: "desk",
      asset_id: "desk-a1-01",
      level_id: "zone-level-a1",
      day_offset: 1,
      number_of_days: 1,
    ).get

    system(:StaffAPI)[:bookings_created].as_i.should eq created_before + 1
    zones = system(:StaffAPI)[:last_booking_zones].as_a.map(&.as_s)
    zones.should contain "zone-level-a1"
    zones.should contain "zone-building-a"
    zones.should contain "zone-org"

    system(:StaffAPI)[:last_booking_type].as_s.should eq "desk"
    system(:StaffAPI)[:last_booking_asset].as_s.should eq "desk-a1-01"

    result["booking_ids"].as_a.size.should eq 1
  end

  it "book_relative uses the building's own timezone" do
    exec(
      :book_relative,
      building_id: "zone-building-b",
      booking_type: "desk",
      asset_id: "desk-b1-01",
      level_id: "zone-level-b1",
      day_offset: 1,
      number_of_days: 1,
    ).get

    system(:StaffAPI)[:last_booking_timezone].as_s.should eq "America/New_York"
  end

  it "book_relative rejects an unknown level for the building" do
    expect_raises(Exception, /could not find level_id/) do
      exec(
        :book_relative,
        building_id: "zone-building-a",
        booking_type: "desk",
        asset_id: "desk-a1-01",
        level_id: "zone-level-b1", # belongs to building B, not A
        day_offset: 1,
        number_of_days: 1,
      ).get
    end
  end

  it "invite tags the visitor booking with the requested building" do
    created_before = system(:StaffAPI)[:bookings_created].as_i

    exec(
      :invite,
      building_id: "zone-building-b",
      visitor_name: "Jane Visitor",
      visitor_email: "jane@guest.com",
      day_offset: 1,
      number_of_days: 1,
    ).get

    system(:StaffAPI)[:bookings_created].as_i.should eq created_before + 1
    system(:StaffAPI)[:last_booking_type].as_s.should eq "visitor"
    system(:StaffAPI)[:last_booking_asset].as_s.should eq "jane@guest.com"

    zones = system(:StaffAPI)[:last_booking_zones].as_a.map(&.as_s)
    zones.should contain "zone-building-b"
    zones.should contain "zone-org"
    # a level from building B must have been selected
    zones.should contain "zone-level-b1"
  end

  it "rejects a new desk booking when the user already has an overlapping desk booking" do
    system(:StaffAPI).as(StaffAPI).arm_existing_desk_booking(true)
    begin
      expect_raises(Exception, /already have a desk booking/) do
        exec(
          :book_relative,
          building_id: "zone-building-a",
          booking_type: "desk",
          asset_id: "desk-a1-01",
          level_id: "zone-level-a1",
          day_offset: 1,
          number_of_days: 1,
        ).get
      end
    ensure
      system(:StaffAPI).as(StaffAPI).arm_existing_desk_booking(false)
    end
  end

  it "snaps a today booking start time to the next 10-minute interval" do
    # the building's timezone determines whether today bookings are still
    # permitted - the driver only allows them before 6pm local time. Pick the
    # building whose local time is currently before that cutoff.
    sydney = Time::Location.load("Australia/Sydney")
    ny = Time::Location.load("America/New_York")

    building_id, tz = if Time.local(sydney).hour < 18
                        {"zone-building-a", sydney}
                      elsif Time.local(ny).hour < 18
                        {"zone-building-b", ny}
                      else
                        {nil, nil}
                      end

    if building_id && tz
      before_unix = Time.utc.to_unix
      exec(
        :book_relative,
        building_id: building_id,
        booking_type: "desk",
        asset_id: building_id == "zone-building-a" ? "desk-a1-01" : "desk-b1-01",
        level_id: building_id == "zone-building-a" ? "zone-level-a1" : "zone-level-b1",
        day_offset: 0,
        number_of_days: 1,
      ).get

      booking_start = system(:StaffAPI)[:last_booking_start].as_i64
      # aligned to a 10-minute boundary (works for whole-hour TZ offsets)
      (booking_start % 600).should eq 0
      # not in the past
      booking_start.should be >= before_unix
      # within ~11 minutes of now (i.e. the next 10-min interval, not 8am)
      (booking_start - before_unix).should be < 11 * 60
    end
  end

  it "applies an explicit booking_start and booking_end window to each day" do
    tz = Time::Location.load("Australia/Sydney")
    # pick a date well into the future so the past-booking check never trips
    # a few days out: clear of the past-booking check, inside the 14 day window
    date = Time.local(tz).at_beginning_of_day + 3.days
    start_time = date + 9.hours + 30.minutes
    end_time = date + 13.hours + 15.minutes

    exec(
      :book_on,
      building_id: "zone-building-a",
      booking_type: "desk",
      asset_id: "desk-a1-01",
      level_id: "zone-level-a1",
      date: date,
      number_of_days: 1,
      booking_start: start_time,
      booking_end: end_time,
    ).get

    system(:StaffAPI)[:last_booking_start].as_i64.should eq start_time.to_unix
    system(:StaffAPI)[:last_booking_end].as_i64.should eq end_time.to_unix
  end

  it "rejects an explicit booking window where end is not after start" do
    tz = Time::Location.load("Australia/Sydney")
    date = Time.local(tz).at_beginning_of_day + 4.days
    start_time = date + 13.hours
    end_time = date + 9.hours

    expect_raises(Exception, /end time .* must be after start time/) do
      exec(
        :book_on,
        building_id: "zone-building-a",
        booking_type: "desk",
        asset_id: "desk-a1-01",
        level_id: "zone-level-a1",
        date: date,
        number_of_days: 1,
        booking_start: start_time,
        booking_end: end_time,
      ).get
    end
  end

  it "refuses to book parking, in either booking function" do
    expect_raises(Exception, /parking bookings are not enabled/) do
      exec(
        :book_relative,
        building_id: "zone-building-a",
        booking_type: "parking",
        asset_id: "park-1",
        level_id: "zone-level-a1",
        day_offset: 1,
      ).get
    end

    expect_raises(Exception, /parking bookings are not enabled/) do
      exec(
        :book_on,
        building_id: "zone-building-a",
        booking_type: "parking",
        asset_id: "park-1",
        level_id: "zone-level-a1",
        date: Time.local(Time::Location.load("Australia/Sydney")).at_beginning_of_day + 2.days,
      ).get
    end
  end

  it "rejects a booking beyond the configured window" do
    expect_raises(Exception, /more than 14 days in advance/) do
      exec(
        :book_relative,
        building_id: "zone-building-a",
        booking_type: "desk",
        asset_id: "desk-a1-01",
        level_id: "zone-level-a1",
        day_offset: 20,
      ).get
    end
  end

  it "writes the mobile app booking payload" do
    exec(
      :book_relative,
      building_id: "zone-building-a",
      booking_type: "desk",
      asset_id: "desk-a1-01",
      level_id: "zone-level-a1",
      day_offset: 1,
    ).get

    staff_api = system(:StaffAPI)
    staff_api[:last_booking_asset_name].as_s.should eq "desk-a1-01"
    staff_api[:last_booking_description].as_s.should eq "desk-a1-01"

    ext = staff_api[:last_booking_extension].as_h
    ext["map_id"].as_s.should eq "desk.a"
    ext["app_name"].as_s.should eq "LLM"
    ext["assigned_asset_id"].as_s.should eq "desk-a1-01"

    # the full zone hierarchy, top-most first
    zones = staff_api[:last_booking_zones].as_a.map(&.as_s)
    zones.should eq ["zone-org", "zone-building-a", "zone-level-a1"]
  end

  it "colleagues reports the building and level each is sitting in" do
    colleagues = exec(:colleagues).get.as_a
    colleagues.size.should eq 5

    one = colleagues.find! { |c| c["email"].as_s == "c1@example.com" }
    one["desk_id"].as_s.should eq "desk-a1-c1"
    one["desk_level_id"].as_s.should eq "zone-level-a1"
    one["desk_building_id"].as_s.should eq "zone-building-a"

    four = colleagues.find! { |c| c["email"].as_s == "c4@example.com" }
    four["desk_building_id"].as_s.should eq "zone-building-b"

    # working from home
    five = colleagues.find! { |c| c["email"].as_s == "c5@example.com" }
    five["desk_id"]?.try(&.as_s?).should be_nil
  end

  it "nearby_desks resolves the building from the level_id alone" do
    nearby = exec(:nearby_desks, level_id: "zone-level-a1", desk_id: "desk-a1-c1").get.as_a.map(&.as_s)

    # desk.a is nearest to c1, then desk.b, then the far-away desk.x. The other
    # colleagues' desks are drawn too, and are returned here - nearby_desks
    # ranks by distance only, it does not filter by availability
    nearby.first.should eq "desk-a1-01"
    nearby.should contain "desk-a1-02"
    nearby.should_not contain "desk-a1-c1"
  end

  it "desks_near_colleagues ranks each building's level by headcount" do
    result = exec(:desks_near_colleagues).get.as_a

    result.map(&.["level_id"].as_s).should eq ["zone-level-a1", "zone-level-b1"]
    result.map(&.["colleagues"].as_a.size).should eq [3, 1]

    # display_name preferred over name, for both the building and the level
    result.map(&.["level_name"].as_s).should eq ["Ground Floor", "Lobby"]

    # who is sitting there, not just how many
    result.first["colleagues"].as_a.map(&.["email"].as_s).sort.should eq [
      "c1@example.com", "c2@example.com", "c3@example.com",
    ]
    result.last["colleagues"].as_a.map(&.["name"].as_s).should eq ["Colleague Four"]

    level_a1 = result.first
    level_a1["building_id"].as_s.should eq "zone-building-a"
    level_a1["building_name"].as_s.should eq "Sydney Tower"
    level_a1["groups"].as_a.map(&.as_s).sort.should eq ["design", "eng", "staff"]

    # desk.a is closest to one colleague but furthest from the other two, so the
    # more central desk.b outranks it. Colleagues' own desks are booked, and
    # desk-a1-03 is restricted to a group the user isn't in, so neither appears.
    level_a1["nearby_desks"].as_a.map(&.as_s).should eq ["desk-a1-02", "desk-a1-01"]

    result.last["building_id"].as_s.should eq "zone-building-b"
    result.last["nearby_desks"].as_a.map(&.as_s).should eq ["desk-b1-01"]
  end

  it "cancel_bookings deletes a booking owned by the user" do
    exec(:cancel_bookings, [600_i64]).get
    system(:StaffAPI)[:bookings_deleted].as_a.map(&.as_i64).should contain 600_i64
  end

  it "exposes capabilities text that instructs the LLM to ask which building" do
    capabilities = exec(:capabilities).get.as_s
    capabilities.downcase.should contain "buildings"
    capabilities.downcase.should contain "ask"
  end
end
