require "placeos-driver/spec"

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
  }

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
    elsif tag_list.includes?("building") && parent == "zone-org"
      [BUILDING_A, BUILDING_B]
    elsif tag_list.includes?("level") && parent == "zone-building-a"
      [LEVEL_A1, LEVEL_A2]
    elsif tag_list.includes?("level") && parent == "zone-building-b"
      [LEVEL_B1]
    else
      [] of typeof(ORG_ZONE)
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
    if key == "desks"
      desks = case id
              when "zone-level-a1"
                [
                  {id: "desk-a1-01", groups: [] of String, features: ["window"]},
                  {id: "desk-a1-02", groups: [] of String, features: [] of String},
                  {id: "desk-a1-03", groups: ["execs"], features: [] of String},
                ]
              when "zone-level-a2"
                [
                  {id: "desk-a2-01", groups: [] of String, features: [] of String},
                ]
              when "zone-level-b1"
                [
                  {id: "desk-b1-01", groups: [] of String, features: ["standing"]},
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
  )
    self[:bookings_created] = self[:bookings_created].as_i + 1
    self[:last_booking_zones] = zones
    self[:last_booking_type] = booking_type
    self[:last_booking_asset] = asset_id
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
    level_a1["bookable_desk_count"].as_i.should eq 3
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
      booking_type: "parking",
      asset_id: "park-1",
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
        booking_type: "parking", # parking skips the desk-conflict check
        asset_id: "park-1",
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
    date = Time.local(2030, 6, 17, 0, 0, 0, location: tz)
    start_time = Time.local(2030, 6, 17, 9, 30, 0, location: tz)
    end_time = Time.local(2030, 6, 17, 13, 15, 0, location: tz)

    exec(
      :book_on,
      building_id: "zone-building-a",
      booking_type: "parking",
      asset_id: "park-1",
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
    date = Time.local(2030, 6, 18, 0, 0, 0, location: tz)
    start_time = Time.local(2030, 6, 18, 13, 0, 0, location: tz)
    end_time = Time.local(2030, 6, 18, 9, 0, 0, location: tz)

    expect_raises(Exception, /end time .* must be after start time/) do
      exec(
        :book_on,
        building_id: "zone-building-a",
        booking_type: "parking",
        asset_id: "park-1",
        level_id: "zone-level-a1",
        date: date,
        number_of_days: 1,
        booking_start: start_time,
        booking_end: end_time,
      ).get
    end
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
