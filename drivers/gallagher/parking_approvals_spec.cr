require "placeos-driver/spec"
require "placeos-driver/interface/mailer"
require "json"

DriverSpecs.mock_driver "Place::Parking::Approvals" do
  system({
    StaffAPI:         {StaffAPIMock},
    Calendar:         {CalendarMock},
    Gallagher:        {GallagherMock},
    LocationServices: {LocationServicesMock},
    Mailer:           {MailerMock},
  })

  settings({
    poll_rate:            999_999,
    cache_days:           14,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "zone-level-B1" => "gallagher-group1",
      "zone-level-B2" => "gallagher-group2",
      "zone-level-B3" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
  })

  staff = system(:StaffAPI).as(StaffAPIMock)
  calendar = system(:Calendar).as(CalendarMock)
  gallagher = system(:Gallagher).as(GallagherMock)
  mailer = system(:Mailer).as(MailerMock)

  # Standard set of parking spaces. car_a sits in the priority zone, car_b is
  # secondary, bike_a is the bike-only space, accessible_a is ACROD-only,
  # assigned_a is permanently assigned.
  default_spaces = [
    {
      id: "asset-car_a", identifier: "BM2.001",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 2.1m", "carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-car_b", identifier: "BM2.002",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-bike_a", identifier: "BM2.M9",
      assigned_to: "", zones: ["zone-building", "zone-level-B3"],
      features: ["bikepriority"] of String, notes: "Bike",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-acrod_a", identifier: "BM2.D1",
      assigned_to: "", zones: ["zone-building", "zone-level-B3"],
      features: ["ACROD", "shared"], notes: "Car",
      security_system_groups: ["gallagher-acrod-group"], bookable: true,
    },
    {
      id: "asset-assigned_a", identifier: "BM2.X1",
      assigned_to: "fixed.user@example.com", zones: ["zone-building", "zone-level-B3"],
      features: [] of String, notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(default_spaces.to_json)

  # Group memberships: priority.user is in group-priority, normal.user only in
  # group-default, external.user is in no groups
  calendar.set_groups("priority.user@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("normal.user@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)
  calendar.set_groups("external.user@example.com", [] of NamedTuple(id: String, email: String))
  calendar.set_groups("after.hours@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("biker@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)
  calendar.set_groups("acrod.user@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)
  calendar.set_groups("fixed.user@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)

  # Cardholder lookup
  gallagher.set_cardholder("priority.user@example.com", "ch-priority")
  gallagher.set_cardholder("normal.user@example.com", "ch-normal")
  gallagher.set_cardholder("after.hours@example.com", "ch-afterhours")
  gallagher.set_cardholder("biker@example.com", "ch-biker")
  gallagher.set_cardholder("acrod.user@example.com", "ch-acrod")
  gallagher.set_cardholder("fixed.user@example.com", "ch-fixed")

  now = Time.utc.to_unix
  start_one = now + 3600
  end_one = now + 7200

  build_booking = ->(id : Int64, user : String, starting : Int64, ending : Int64, asset_id : String, approved : Bool, ext : Hash(String, JSON::Any)) do
    {
      id:              id,
      booking_type:    "parking",
      booking_start:   starting,
      booking_end:     ending,
      asset_id:        asset_id,
      asset_ids:       [asset_id],
      user_id:         "user-#{id}",
      user_email:      user,
      user_name:       user,
      booked_by_email: user,
      booked_by_name:  user,
      zones:           ["zone-building"],
      created:         now - 1000_i64 + id,
      approved:        approved,
      rejected:        false,
      deleted:         false,
      extension_data:  ext,
    }
  end

  ext_car = {"vehicle_type" => JSON::Any.new("car"), "request_type" => JSON::Any.new("standard")}
  ext_bike = {"vehicle_type" => JSON::Any.new("motorcycle"), "request_type" => JSON::Any.new("standard")}
  ext_after_hours_car = {"vehicle_type" => JSON::Any.new("car"), "request_type" => JSON::Any.new("after_hours")}
  ext_acrod = {"vehicle_type" => JSON::Any.new("car"), "space_restrictions" => JSON::Any.new(1_i64)}

  # ===========================================================
  # Test 1: simple car booking gets allocated
  # ===========================================================

  staff.reset_calls
  mailer.reset

  booking_one = build_booking.call(1001_i64, "normal.user@example.com",
    start_one, end_one, "unallocated-1001", false, ext_car)
  staff.set_bookings([booking_one].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(1001_i64).should_not be_nil
  staff.approved.includes?(1001_i64).should eq(true)
  # priority zones are populated first - asset-car_a comes before asset-car_b
  staff.last_update_for(1001_i64).should eq("asset-car_a")
  gallagher.access_for("ch-normal").should contain("gallagher-group1")
  mailer.last_template.should eq(["parking_request", "approved"])
  mailer.last_to.should eq("normal.user@example.com")
  staff.last_state(1001_i64).should eq("access_granted")

  # ===========================================================
  # Test 2: bike booking is allocated to bike space (not car)
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  bike_booking = build_booking.call(2001_i64, "biker@example.com",
    now + 3600 * 24, now + 3600 * 25, "unallocated-2001", false, ext_bike)
  staff.set_bookings([bike_booking].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(2001_i64).should eq("asset-bike_a")
  gallagher.access_for("ch-biker").should contain("gallagher-group3")

  # ===========================================================
  # Test 3: after-hours booking, not approved -> manual approval email,
  # no allocation
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  ah_booking = build_booking.call(3001_i64, "after.hours@example.com",
    now + 3600 * 26, now + 3600 * 27, "unallocated-3001", false, ext_after_hours_car)
  staff.set_bookings([ah_booking].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(3001_i64).should be_nil
  staff.approved.includes?(3001_i64).should eq(false)
  staff.last_state(3001_i64).should eq("waiting_approval")
  mailer.last_template.should eq(["parking_request", "approval_required"])

  # ===========================================================
  # Test 4: after-hours booking that has been pre-approved -> allocated
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  approved_ah = build_booking.call(4001_i64, "after.hours@example.com",
    now + 3600 * 28, now + 3600 * 29, "unallocated-4001", true, ext_after_hours_car)
  staff.set_bookings([approved_ah].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(4001_i64).should eq("asset-car_a")
  gallagher.access_for("ch-afterhours").should contain("gallagher-group1")
  staff.last_state(4001_i64).should eq("access_granted")

  # ===========================================================
  # Test 5: priority preemption — higher priority displaces lower priority.
  # normal.user already has asset-car_a, priority.user requests at the same
  # time and should get the space. normal.user is moved to wait list.
  # ===========================================================

  staff.reset_calls
  mailer.reset

  # only 1 car space available so the preemption outcome is deterministic
  preempt_spaces = [default_spaces[0]] # asset-car_a only
  staff.set_assets(preempt_spaces.to_json)

  preempt_start = now + 3600 * 30
  preempt_end = now + 3600 * 31

  existing_normal = build_booking.call(5001_i64, "normal.user@example.com",
    preempt_start, preempt_end, "asset-car_a", true, ext_car)

  high_priority = build_booking.call(5003_i64, "priority.user@example.com",
    preempt_start, preempt_end, "unallocated-5003", false, ext_car)

  staff.set_bookings([existing_normal, high_priority].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # priority.user took asset-car_a
  staff.last_update_for(5003_i64).should eq("asset-car_a")
  staff.approved.includes?(5003_i64).should eq(true)
  gallagher.access_for("ch-priority").should contain("gallagher-group1")

  # normal.user got displaced (asset_id set back to unallocated-displaced-)
  displaced = staff.last_update_for(5001_i64).not_nil!
  displaced.starts_with?("unallocated-displaced").should eq(true)
  staff.last_state(5001_i64).should eq("wait_list")

  # ===========================================================
  # Test 6: wait list when no compatible space (all car spaces taken)
  # ===========================================================

  staff.reset_calls
  mailer.reset

  # only one car space available
  one_space = [default_spaces[0]]
  staff.set_assets(one_space.to_json)

  wl_start = now + 3600 * 40
  wl_end = now + 3600 * 41

  taken = build_booking.call(6001_i64, "priority.user@example.com",
    wl_start, wl_end, "asset-car_a", true, ext_car)
  loser = build_booking.call(6002_i64, "normal.user@example.com",
    wl_start, wl_end, "unallocated-6002", false, ext_car)

  staff.set_bookings([taken, loser].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # loser stays unallocated, no update
  staff.last_update_for(6002_i64).should be_nil
  staff.last_state(6002_i64).should eq("wait_list")

  # ===========================================================
  # Test 7: ACROD restriction filters to the ACROD space
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  acrod_booking = build_booking.call(7001_i64, "acrod.user@example.com",
    now + 3600 * 50, now + 3600 * 51, "unallocated-7001", false, ext_acrod)
  staff.set_bookings([acrod_booking].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(7001_i64).should eq("asset-acrod_a")
  # uses the per-asset security_system_groups override
  gallagher.access_for("ch-acrod").should contain("gallagher-acrod-group")

  # ===========================================================
  # Test 8: permanently assigned space grants gallagher access
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-fixed").should contain("gallagher-group3")

  # ===========================================================
  # Test 9: diff/apply — once a booking is gone the user is removed
  # from the gallagher group on the next sweep
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  removable = build_booking.call(9001_i64, "normal.user@example.com",
    now + 3600 * 60, now + 3600 * 61, "unallocated-9001", false, ext_car)
  staff.set_bookings([removable].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-normal").should contain("gallagher-group1")

  # next run with no bookings — user should lose access
  staff.reset_calls
  mailer.reset
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-normal").should_not contain("gallagher-group1")

  # ===========================================================
  # Test 10: feature-priority sort actually drives selection.
  # Spaces are deliberately listed in reverse priority order so the test
  # would fail if we fell back to asset-list order:
  #   1. no-feature  (priority idx = Int32::MAX)
  #   2. shared      (priority idx 1 — second in car_zone_priority)
  #   3. carpriority (priority idx 0 — first in car_zone_priority)
  # Three sequential single-booking sweeps should allocate them in priority
  # order: carpriority -> shared -> no-feature.
  # ===========================================================

  priority_test_spaces = [
    {
      id: "asset-no_pref", identifier: "BM2.N1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: [] of String, notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-shared_pref", identifier: "BM2.S1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-high_pref", identifier: "BM2.H1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(priority_test_spaces.to_json)

  prio_start = now + 3600 * 80
  prio_end = prio_start + 3600

  # 1st request — must go to the "carpriority" space (idx 0) even though
  # it is listed LAST among the assets
  staff.reset_calls
  mailer.reset
  staff.set_bookings([
    build_booking.call(10001_i64, "normal.user@example.com",
      prio_start, prio_end, "unallocated-10001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  staff.last_update_for(10001_i64).should eq("asset-high_pref")

  # 2nd request overlaps the first — high_pref is occupied so the next-best
  # remaining space is "shared" (idx 1), not the no-feature space
  staff.reset_calls
  mailer.reset
  staff.set_bookings([
    build_booking.call(10001_i64, "normal.user@example.com",
      prio_start, prio_end, "asset-high_pref", true, ext_car),
    build_booking.call(10002_i64, "biker@example.com",
      prio_start, prio_end, "unallocated-10002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  staff.last_update_for(10002_i64).should eq("asset-shared_pref")

  # 3rd request overlapping both — only the no-feature space remains
  staff.reset_calls
  mailer.reset
  staff.set_bookings([
    build_booking.call(10001_i64, "normal.user@example.com",
      prio_start, prio_end, "asset-high_pref", true, ext_car),
    build_booking.call(10002_i64, "biker@example.com",
      prio_start, prio_end, "asset-shared_pref", true, ext_car),
    build_booking.call(10003_i64, "acrod.user@example.com",
      prio_start, prio_end, "unallocated-10003", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  staff.last_update_for(10003_i64).should eq("asset-no_pref")
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @assets_json : String = "[]"
  @bookings_json : String = "[]"
  @updates : Hash(Int64, String) = {} of Int64 => String
  @approved_set : Array(Int64) = [] of Int64
  @states : Hash(Int64, String) = {} of Int64 => String

  def on_load
    self[:zone_lookups] = 0
  end

  def set_assets(json : String)
    @assets_json = json
  end

  def set_bookings(json : String)
    @bookings_json = json
  end

  def reset_calls
    @updates = {} of Int64 => String
    @approved_set = [] of Int64
    @states = {} of Int64 => String
  end

  def last_update_for(booking_id : Int64) : String?
    @updates[booking_id]?
  end

  def approved : Array(Int64)
    @approved_set
  end

  def last_state(booking_id : Int64) : String?
    @states[booking_id]?
  end

  def zone(zone_id : String)
    {
      id:           zone_id,
      name:         "Mock Building",
      display_name: "Mock Building",
      location:     "",
      tags:         ["building"],
      parent_id:    nil,
    }
  end

  def asset_categories(hidden : Bool? = nil)
    [{id: "cat-parking", name: "_PARKING_"}]
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-spaces", name: "_PARKING_SPACES_"}]
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
  )
    JSON.parse(@assets_json)
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
    JSON.parse(@bookings_json)
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    bookings = JSON.parse(@bookings_json).as_a
    found = bookings.find { |b| b["id"].as_i64 == booking_id.to_s.to_i64 }
    found || JSON::Any.new({} of String => JSON::Any)
  end

  def update_booking(
    booking_id : String | Int64,
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    asset_id : String? = nil,
    title : String? = nil,
    description : String? = nil,
    timezone : String? = nil,
    extension_data : JSON::Any? = nil,
    approved : Bool? = nil,
    checked_in : Bool? = nil,
    limit_override : Int64? = nil,
    instance : Int64? = nil,
    recurrence_end : Int64? = nil,
  )
    if asset_id
      @updates[booking_id.to_s.to_i64] = asset_id
    end
    true
  end

  def approve(booking_id : String | Int64, instance : Int64? = nil)
    @approved_set << booking_id.to_s.to_i64
    true
  end

  def reject(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    true
  end

  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    @states[booking_id.to_s.to_i64] = state
    true
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  @groups : Hash(String, String) = {} of String => String

  def set_groups(user_email : String, groups_json : String)
    @groups[user_email.downcase] = groups_json
  end

  def set_groups(user_email : String, groups : Array(NamedTuple(id: String, email: String)))
    @groups[user_email.downcase] = groups.to_json
  end

  def get_groups(user_id : String)
    raw = @groups[user_id.downcase]?
    raw ? JSON.parse(raw) : JSON.parse("[]")
  end

  def get_user(user_id : String, additional_fields : Array(String)? = nil)
    {email: user_id, name: user_id}
  end
end

# :nodoc:
class GallagherMock < DriverSpecs::MockDriver
  @cardholders : Hash(String, String) = {} of String => String
  @memberships : Hash(String, Array(String)) = {} of String => Array(String)

  def set_cardholder(email : String, cardholder_id : String)
    @cardholders[email.downcase] = cardholder_id
  end

  def reset
    @memberships = {} of String => Array(String)
  end

  def access_for(cardholder_id : String) : Array(String)
    @memberships[cardholder_id]? || [] of String
  end

  def card_holder_id_lookup(email : String)
    @cardholders[email.downcase]?
  end

  def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64)
    list = @memberships[card_holder_id.to_s]?
    return nil unless list
    list.includes?(zone_id.to_s) ? "href-#{zone_id}-#{card_holder_id}" : nil
  end

  def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    list = @memberships[card_holder_id.to_s] ||= [] of String
    list << zone_id.to_s unless list.includes?(zone_id.to_s)
    true
  end

  def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64)
    list = @memberships[card_holder_id.to_s]?
    list.try(&.delete(zone_id.to_s))
    true
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def building_id
    "zone-building"
  end

  def bookings_for(email : String)
    [] of JSON::Any
  end
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  @sent : Array(NamedTuple(to: String, template: Tuple(String, String))) = [] of NamedTuple(to: String, template: Tuple(String, String))

  def reset
    @sent = [] of NamedTuple(to: String, template: Tuple(String, String))
    self[:send_count] = 0
    self[:last_template] = nil
    self[:last_to] = nil
  end

  def last_template
    self[:last_template]
  end

  def last_to
    self[:last_to]
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : (String | Array(String))? = nil,
    reply_to : (String | Array(String))? = nil,
  )
    self[:last_template] = template
    self[:last_to] = to.is_a?(String) ? to : to.first?
    self[:send_count] = (self[:send_count]?.try(&.as_i) || 0) + 1
    true
  end

  def send_mail(
    to : String | Array(String),
    subject : String,
    message_plaintext : String? = nil,
    message_html : String? = nil,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : (String | Array(String))? = nil,
    reply_to : (String | Array(String))? = nil,
  ) : Bool
    true
  end
end
