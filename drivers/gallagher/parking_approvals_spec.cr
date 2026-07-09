require "placeos-driver/spec"
require "placeos-driver/interface/mailer"
require "base64"
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
    poll_rate:                       999_999,
    cache_days:                      14,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
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
      features: ["Max height 2.1m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-car_b", identifier: "BM2.002",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-bike_a", identifier: "BM2.M9",
      assigned_to: "", zones: ["zone-building", "zone-level-B3"],
      features: ["bikepriority", "Secure Basement"], notes: "Bike",
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
      features: ["Secure Basement"], notes: "Car",
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
  # height restrictions: id 4 => "Max height 1.95m", id 5 => "Max height 2.1m"
  ext_h195 = {"vehicle_type" => JSON::Any.new("car"), "space_restrictions" => JSON::Any.new(4_i64)}
  ext_h210 = {"vehicle_type" => JSON::Any.new("car"), "space_restrictions" => JSON::Any.new(5_i64)}

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
  # both car spaces share the carpriority zone, so the smaller-height space
  # (car_b, 1.95m) is preferred over car_a (2.1m) to keep taller spaces free
  staff.last_update_for(1001_i64).should eq("asset-car_b")
  gallagher.access_for("ch-normal").should contain("gallagher-group1")
  # approval email uses the per-area trigger (Open Basement -> gallagher-group1)
  mailer.last_template.should eq(["parking_request", "approved_gallagher-group1"])
  mailer.last_to.should eq("normal.user@example.com")
  staff.last_state(1001_i64).should eq("access_granted_emailed")

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
  # a different parking area (Secure Basement -> group3) -> a different trigger
  mailer.last_template.should eq(["parking_request", "approved_gallagher-group3"])

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

  # smaller-height car_b preferred within the shared carpriority zone
  staff.last_update_for(4001_i64).should eq("asset-car_b")
  gallagher.access_for("ch-afterhours").should contain("gallagher-group1")
  staff.last_state(4001_i64).should eq("access_granted_emailed")

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
  # the override group is not a parking_areas area, so the approval email falls
  # back to the generic "approved" template (no per-area template for overrides)
  mailer.last_template.should eq(["parking_request", "approved"])

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
      features: ["Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-shared_pref", identifier: "BM2.S1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-high_pref", identifier: "BM2.H1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
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

  # ===========================================================
  # Test 11: approved email sends exactly ONCE across repeated polls for a
  # recurring booking instance. Regression guard for the duplicate-email bug:
  # the dedup relies on process_state, which must be persisted + reflected
  # PER INSTANCE (booking instances carry their own process_state). The mock
  # reflects booking_state writes per "id:instance" on re-fetch, so polling
  # the same already-allocated instance repeatedly must not re-notify.
  # NOTE: reset_calls is intentionally NOT called between polls so the
  # persisted per-instance state carries across sweeps (as in production).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_assets(default_spaces.to_json)

  recurring_instance = {
    id:              11001_i64,
    instance:        now + 3600 * 90, # recurring instance identifier
    booking_type:    "parking",
    booking_start:   now + 3600 * 90,
    booking_end:     now + 3600 * 91,
    asset_id:        "asset-car_a",
    asset_ids:       ["asset-car_a"],
    user_id:         "user-11001",
    user_email:      "normal.user@example.com",
    user_name:       "normal.user@example.com",
    booked_by_email: "normal.user@example.com",
    booked_by_name:  "normal.user@example.com",
    zones:           ["zone-building"],
    created:         now,
    approved:        true,
    rejected:        false,
    deleted:         false,
    extension_data:  ext_car,
  }
  staff.set_bookings([recurring_instance].to_json)

  # first sweep emails exactly once and records access_granted on the instance
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  mailer.send_count.should eq(1)
  mailer.last_template.should eq(["parking_request", "approved_gallagher-group1"])
  staff.last_state(11001_i64, now + 3600 * 90).should eq("access_granted_emailed")

  # subsequent sweeps must NOT re-send — the per-instance process_state is
  # reflected on re-fetch and guards the email
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  mailer.send_count.should eq(1)

  # ===========================================================
  # Test 12: the allocation window ends at the upcoming Friday 13:00 in the
  # configured timezone (control_system timezone is Australia/Sydney in specs).
  # Once Friday 13:00 has passed the window rolls to the following Friday.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  tz = Time::Location.load("Australia/Sydney")
  now_local = Time.local(tz)
  days_until_friday = (Time::DayOfWeek::Friday.value - now_local.day_of_week.value) % 7
  friday_local = now_local + days_until_friday.days
  expected_end = Time.local(friday_local.year, friday_local.month, friday_local.day, 13, 0, 0, location: tz)
  expected_end = expected_end.shift(days: 7) if expected_end <= now_local

  period_end = staff.last_query_period_end.not_nil!
  period_end.should eq(expected_end.to_unix)

  cutoff = Time.unix(period_end).in(tz)
  cutoff.day_of_week.should eq(Time::DayOfWeek::Friday)
  cutoff.hour.should eq(13)
  cutoff.minute.should eq(0)
  # the window always ends in the future
  (cutoff > now_local).should eq(true)

  # ===========================================================
  # Directory-resolved Gallagher lookups (employeeId via MS Graph).
  # A single bookable car space mapped to gallagher-group1 is reused.
  # ===========================================================

  emp_spaces = [
    {
      id: "asset-emp_a", identifier: "EMP.001",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]

  default_grp = [{id: "group-default", email: "default@grp.com"}]

  # regression guard: with a blank gallagher_id_field (Tests 1-12) the directory
  # is NEVER consulted — get_user must not have been called, so the captured
  # additional_fields stays nil (the mock only sets it on a get_user call)
  calendar.last_additional_fields.should be_nil

  # enable directory resolution: look users up in the directory and read their
  # "employeeId" from unmapped, then query Gallagher with that value
  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
    gallagher_id_field: "employeeId",
  })
  sleep 100.milliseconds

  # ===========================================================
  # Test 13: cardholder resolved via the employee id (NOT the email)
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  calendar.set_user_employee_id("philip@example.com", "HI200761")
  gallagher.set_cardholder("HI200761", "ch-philip")
  # a DIFFERENT cardholder is registered under the email — if the driver wrongly
  # looked Gallagher up by email this one would receive access instead
  gallagher.set_cardholder("philip@example.com", "ch-email-philip")
  calendar.set_groups("philip@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(13001_i64, "philip@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # access is granted to the employee-id-resolved cardholder
  gallagher.access_for("ch-philip").should contain("gallagher-group1")
  # the email-keyed cardholder was NOT granted access (email path not taken)
  gallagher.access_for("ch-email-philip").should be_empty
  # the directory was queried for the configured field (defaulted from id field)
  calendar.last_additional_fields.should eq(["employeeId"])
  status[:lookup_error_count].as_i.should eq(0)

  # ===========================================================
  # Test 14: employee id resolves but Gallagher has no cardholder -> error
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  calendar.set_user_employee_id("nocard@example.com", "HI999999")
  # deliberately no gallagher cardholder registered for HI999999
  calendar.set_groups("nocard@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(14001_i64, "nocard@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  status[:lookup_error_count].as_i.should eq(1)
  err = status[:lookup_errors].as_a.first
  err["email"].as_s.should eq("nocard@example.com")
  err["employee_id"].as_s.should eq("HI999999")
  err["reason"].as_s.should eq("no gallagher cardholder found")

  # ===========================================================
  # Test 15: directory yields no employee id -> error; cleared next sync
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  # user with no employeeId surfaced by the directory (default get_user payload)
  calendar.set_groups("noemp@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(15001_i64, "noemp@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  status[:lookup_error_count].as_i.should eq(1)
  missing = status[:lookup_errors].as_a.first
  missing["email"].as_s.should eq("noemp@example.com")
  missing["employee_id"].raw.should be_nil
  missing["reason"].as_s.should eq("directory field 'employeeId' not found for user")

  # a subsequent sync with a fully-resolvable user clears the prior errors
  staff.reset_calls
  mailer.reset
  gallagher.reset

  calendar.set_user_employee_id("resolves@example.com", "HI111111")
  gallagher.set_cardholder("HI111111", "ch-resolves")
  calendar.set_groups("resolves@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(15002_i64, "resolves@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  status[:lookup_error_count].as_i.should eq(0)
  gallagher.access_for("ch-resolves").should contain("gallagher-group1")

  # ===========================================================
  # Test 16: a numeric directory employeeId resolves to an Int64 Gallagher
  # cardholder id (exercises the JSON-number paths in unmapped_value and the
  # .as_i64? branch of the cardholder lookup).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  # directory surfaces employeeId as a JSON number; Gallagher returns an Int64 id
  calendar.set_user_employee_id("numeric@example.com", 5005_i64)
  gallagher.set_cardholder("5005", 9001_i64)
  calendar.set_groups("numeric@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(16001_i64, "numeric@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # membership is keyed by the resolved Int64 cardholder id (9001)
  gallagher.access_for("9001").should contain("gallagher-group1")
  status[:lookup_error_count].as_i.should eq(0)

  # ===========================================================
  # Test 17: the same unresolvable user across multiple bookings in one sync
  # produces a SINGLE error (per-sync dedup via @failed_lookups), not one per
  # booking.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  # no employeeId in the directory -> every lookup for this user fails
  calendar.set_groups("dedupe@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(17001_i64, "dedupe@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
    build_booking.call(17002_i64, "dedupe@example.com",
      now + 3600 * 7, now + 3600 * 8, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # two bookings, same failing user -> exactly one recorded error
  status[:lookup_error_count].as_i.should eq(1)
  status[:lookup_errors].as_a.first["email"].as_s.should eq("dedupe@example.com")

  # ===========================================================
  # Test 18: a user with no Gallagher card has their booking WITHHELD (not
  # approved/allocated), is notified once, persisted to the no-card list, and is
  # only allocated once a card exists (and then dropped from the list).
  # ===========================================================

  # --- sweep 1: no card -> withhold + notify once ---
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  calendar.set_user_employee_id("waiting@example.com", "HI777")
  # no gallagher cardholder registered for HI777 -> user has no card
  calendar.set_groups("waiting@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(18001_i64, "waiting@example.com",
      now + 3600 * 5, now + 3600 * 6, "unallocated-18001", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # withheld: not approved, not allocated
  staff.approved.includes?(18001_i64).should eq(false)
  staff.last_update_for(18001_i64).should be_nil
  # notified once via the no_card template
  mailer.last_template.should eq(["parking_request", "no_card"])
  mailer.last_to.should eq("waiting@example.com")
  mailer.send_count.should eq(1)
  # recorded on the persisted no-card list
  status[:users_without_cards].as_a.map(&.as_s).should contain("waiting@example.com")

  # --- sweep 2: still no card -> NOT re-notified (already on the list) ---
  staff.reset_calls
  mailer.reset
  staff.set_bookings([
    build_booking.call(18001_i64, "waiting@example.com",
      now + 3600 * 5, now + 3600 * 6, "unallocated-18001", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.approved.includes?(18001_i64).should eq(false)
  mailer.send_count.should eq(0)

  # --- sweep 3: user now has a card -> allocated, approved, removed from list ---
  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("HI777", "ch-waiting")
  staff.set_bookings([
    build_booking.call(18001_i64, "waiting@example.com",
      now + 3600 * 5, now + 3600 * 6, "unallocated-18001", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.approved.includes?(18001_i64).should eq(true)
  staff.last_update_for(18001_i64).should eq("asset-emp_a")
  gallagher.access_for("ch-waiting").should contain("gallagher-group1")
  mailer.last_template.should eq(["parking_request", "approved_gallagher-group1"])
  # dropped from the no-card list once a card exists
  status[:users_without_cards].as_a.map(&.as_s).should_not contain("waiting@example.com")

  # ===========================================================
  # Test 19: requested field casing differs from the unmapped key.
  # MS Graph returns "employeeId" for a requested "employeeid" — the
  # case-insensitive unmapped read must still resolve the cardholder.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
    gallagher_id_field: "employeeid",
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(emp_spaces.to_json)

  # config requests lowercase "employeeid" but the directory surfaces camelCase
  calendar.set_user_employee_id("jane@example.com", "HI300002", key: "employeeId")
  gallagher.set_cardholder("HI300002", "ch-jane")
  calendar.set_groups("jane@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(16001_i64, "jane@example.com",
      now + 3600 * 5, now + 3600 * 6, "asset-emp_a", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-jane").should contain("gallagher-group1")
  calendar.last_additional_fields.should eq(["employeeid"])
  status[:lookup_error_count].as_i.should eq(0)

  # ===========================================================
  # Test 20: with all spaces full across MULTIPLE priority levels, a high
  # priority request preempts the LOWEST-priority occupant (not just any lower
  # one), so only a single user is displaced — no cascade. Back on the
  # email-lookup config for clarity.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset

  # two car spaces; the MID holder sits in the MORE-preferred space (carpriority)
  # and the LOW holder in the less-preferred (shared). The old "first lower
  # occupant" logic would wrongly bump MID (preferred space, found first);
  # the correct logic bumps LOW (lowest priority).
  prio_spaces = [
    {
      id: "asset-prefa", identifier: "PA",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-prefb", identifier: "PB",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(prio_spaces.to_json)

  # three priority tiers: top (group-priority=2) > mid (group-default=1) > low (no group=0)
  calendar.set_groups("top.user@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("mid.user@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)
  calendar.set_groups("low.user@example.com", [] of NamedTuple(id: String, email: String))
  gallagher.set_cardholder("top.user@example.com", "ch-top")
  gallagher.set_cardholder("mid.user@example.com", "ch-mid")
  gallagher.set_cardholder("low.user@example.com", "ch-low")

  cstart = now + 3600 * 400
  cend = cstart + 3600
  staff.set_bookings([
    # MID holds the preferred space, LOW holds the less-preferred one
    build_booking.call(80001_i64, "mid.user@example.com",
      cstart, cend, "asset-prefa", true, ext_car),
    build_booking.call(80002_i64, "low.user@example.com",
      cstart, cend, "asset-prefb", true, ext_car),
    # TOP requests during the same window with nothing free
    build_booking.call(80003_i64, "top.user@example.com",
      cstart, cend, "unallocated-80003", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # TOP takes the LOW holder's space (lowest priority displaced)
  staff.last_update_for(80003_i64).should eq("asset-prefb")
  staff.approved.includes?(80003_i64).should eq(true)

  # LOW is the one displaced + emailed + moved to the wait list
  staff.last_update_for(80002_i64).not_nil!.starts_with?("unallocated-displaced").should eq(true)
  staff.last_state(80002_i64).should eq("wait_list")
  mailer.sent?("low.user@example.com", "parking_request", "displaced").should eq(true)

  # MID is untouched — keeps the preferred space, never displaced
  staff.last_update_for(80001_i64).should be_nil
  staff.last_state(80001_i64).should eq("access_granted_emailed")
  mailer.sent?("mid.user@example.com", "parking_request", "displaced").should eq(false)

  # ===========================================================
  # Time-bounded access. Reconfigure with a known access_minutes_before and a
  # single car space mapped to gallagher-group1 (email-lookup path).
  # ===========================================================

  win_settings = {
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
    access_minutes_before: 45,
  }
  settings(win_settings)
  sleep 100.milliseconds

  win_spaces = [
    {
      id: "asset-win", identifier: "WIN",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]

  # ===========================================================
  # Test 21: a booking grants a time-bounded window — until == booking end,
  # from == booking start - access_minutes_before*60.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(win_spaces.to_json)

  gallagher.set_cardholder("win.user@example.com", "ch-win")
  calendar.set_groups("win.user@example.com", default_grp.to_json)

  wstart = now + 3600_i64 * 100
  wend = wstart + 3600_i64
  staff.set_bookings([
    build_booking.call(21001_i64, "win.user@example.com",
      wstart, wend, "asset-win", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-win").should contain("gallagher-group1")
  # exactly one window, ending at the booking end
  gallagher.untils_for("ch-win", "gallagher-group1").should eq([wend])
  # start margin honours access_minutes_before (45 min)
  gallagher.from_for("ch-win", "gallagher-group1", wend).should eq(wstart - 45_i64 * 60)

  # ===========================================================
  # Test 22: when the booking is gone, the windowed grant is removed (matched
  # by until). NOTE: gallagher is NOT reset so we observe the removal.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-win").should be_empty

  # ===========================================================
  # Test 23: a user with two bookings (different days) in the same group holds
  # two distinct windows — one per booking end.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  multi_spaces = [
    {
      id: "asset-m1", identifier: "M1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-m2", identifier: "M2",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(multi_spaces.to_json)
  gallagher.set_cardholder("multi.user@example.com", "ch-multi")
  calendar.set_groups("multi.user@example.com", default_grp.to_json)

  d1s = now + 3600_i64 * 120
  d1e = d1s + 3600_i64
  d2s = now + 3600_i64 * 144
  d2e = d2s + 3600_i64
  staff.set_bookings([
    build_booking.call(23001_i64, "multi.user@example.com",
      d1s, d1e, "asset-m1", true, ext_car),
    build_booking.call(23002_i64, "multi.user@example.com",
      d2s, d2e, "asset-m2", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # both bookings map to gallagher-group1 — two distinct end windows tracked
  multi_untils = gallagher.untils_for("ch-multi", "gallagher-group1")
  multi_untils.size.should eq(2)
  multi_untils.compact.sort.should eq([d1e, d2e].sort)

  # ===========================================================
  # Test 24: a permanently-assigned space grants standing (unbounded) access —
  # the window's until is nil (general access).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  assigned_only = [
    {
      id: "asset-perm", identifier: "PERM",
      assigned_to: "perm.user@example.com", zones: ["zone-building", "zone-level-B1"],
      features: ["Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(assigned_only.to_json)
  gallagher.set_cardholder("perm.user@example.com", "ch-perm")
  calendar.set_groups("perm.user@example.com", default_grp.to_json)
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.access_for("ch-perm").should contain("gallagher-group1")
  gallagher.untils_for("ch-perm", "gallagher-group1").should eq([nil])

  # ===========================================================
  # Test 25: access_minutes_before is configurable — a different value changes
  # the grant's start margin (and only the margin; until still == booking end).
  # ===========================================================

  settings(win_settings.merge({access_minutes_before: 10}))
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(win_spaces.to_json)
  gallagher.set_cardholder("margin.user@example.com", "ch-margin")
  calendar.set_groups("margin.user@example.com", default_grp.to_json)

  mstart = now + 3600_i64 * 160
  mend = mstart + 3600_i64
  staff.set_bookings([
    build_booking.call(25001_i64, "margin.user@example.com",
      mstart, mend, "asset-win", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  gallagher.untils_for("ch-margin", "gallagher-group1").should eq([mend])
  gallagher.from_for("ch-margin", "gallagher-group1", mend).should eq(mstart - 10_i64 * 60)

  # ===========================================================
  # Test 26: two same-user bookings in the same group sharing an end time but
  # with DIFFERENT starts collapse to one window — keep the EARLIEST start so
  # the granted window spans both (no access gap). Regression for the grant_key
  # collision (email|until) merge.
  # ===========================================================

  settings(win_settings) # access_minutes_before back to 45
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  # two car spaces, both -> gallagher-group1 (feature "Open Basement")
  collide_spaces = [
    {
      id: "asset-c1", identifier: "C1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-c2", identifier: "C2",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(collide_spaces.to_json)
  gallagher.set_cardholder("collide.user@example.com", "ch-collide")
  calendar.set_groups("collide.user@example.com", default_grp.to_json)

  shared_end = now + 3600_i64 * 180
  early_start = shared_end - 3600_i64 * 6 # earlier start
  late_start = shared_end - 3600_i64 * 2  # later start, same end
  staff.set_bookings([
    build_booking.call(26001_i64, "collide.user@example.com",
      early_start, shared_end, "asset-c1", true, ext_car),
    build_booking.call(26002_i64, "collide.user@example.com",
      late_start, shared_end, "asset-c2", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # exactly one window (collapsed), ending at the shared end
  gallagher.untils_for("ch-collide", "gallagher-group1").should eq([shared_end])
  # and it spans BOTH bookings: from == earliest start - margin (45m)
  gallagher.from_for("ch-collide", "gallagher-group1", shared_end).should eq(early_start - 45_i64 * 60)

  # ===========================================================
  # Test 27: a rescheduled booking (moved end time) moves the window — the old
  # until is removed and exactly the new one remains. No gallagher.reset between
  # the two sweeps so the removal is observable.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(win_spaces.to_json)
  gallagher.set_cardholder("resched.user@example.com", "ch-resched")
  calendar.set_groups("resched.user@example.com", default_grp.to_json)

  rstart = now + 3600_i64 * 200
  rend = rstart + 3600_i64
  staff.set_bookings([
    build_booking.call(27001_i64, "resched.user@example.com",
      rstart, rend, "asset-win", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  gallagher.untils_for("ch-resched", "gallagher-group1").should eq([rend])

  # reschedule the SAME booking to a later end (no reset)
  rend2 = rend + 3600_i64 * 24
  staff.set_bookings([
    build_booking.call(27001_i64, "resched.user@example.com",
      rstart, rend2, "asset-win", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # old window gone, exactly one new window at the moved end
  gallagher.untils_for("ch-resched", "gallagher-group1").should eq([rend2])
  gallagher.from_for("ch-resched", "gallagher-group1", rend2).should eq(rstart - 45_i64 * 60)

  # ===========================================================
  # Test 28: changing access_minutes_before must NOT orphan or duplicate an
  # already-tracked grant — the window key (email|until) is unchanged, so the
  # grant stays in the no-API-call branch and its original start is preserved.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(win_spaces.to_json)
  gallagher.set_cardholder("stable.user@example.com", "ch-stable")
  calendar.set_groups("stable.user@example.com", default_grp.to_json)

  sstart = now + 3600_i64 * 240
  ssend = sstart + 3600_i64
  staff.set_bookings([
    build_booking.call(28001_i64, "stable.user@example.com",
      sstart, ssend, "asset-win", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  gallagher.untils_for("ch-stable", "gallagher-group1").should eq([ssend])
  gallagher.from_for("ch-stable", "gallagher-group1", ssend).should eq(sstart - 45_i64 * 60)

  # change ONLY the margin and re-sweep the SAME booking, WITHOUT gallagher.reset
  settings(win_settings.merge({access_minutes_before: 10}))
  sleep 100.milliseconds
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # untouched: one window, original 45m start margin preserved (no re-add)
  gallagher.untils_for("ch-stable", "gallagher-group1").should eq([ssend])
  gallagher.from_for("ch-stable", "gallagher-group1", ssend).should eq(sstart - 45_i64 * 60)

  # ===========================================================
  # Test 29: a legacy (pre-window) access_granted setting is migrated to a
  # permanent grant, then reconciled to a time window on the next sweep.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(win_spaces.to_json)
  gallagher.set_cardholder("legacy.user@example.com", "ch-legacy")
  calendar.set_groups("legacy.user@example.com", default_grp.to_json)
  # the cardholder already holds the GENERAL membership the legacy entry tracks
  gallagher.zone_access_add_member("gallagher-group1", "ch-legacy", nil, nil)

  # seed the PRE-WINDOW legacy format (group => { email => cardholder_id }) in
  # the SAME settings() call so it isn't overwritten; back to 45m margin
  settings(win_settings.merge({
    access_granted: {"gallagher-group1" => {"legacy.user@example.com" => "ch-legacy"}},
  }))
  sleep 100.milliseconds

  lstart = now + 3600_i64 * 260
  lend = lstart + 3600_i64
  staff.set_bookings([
    build_booking.call(29001_i64, "legacy.user@example.com",
      lstart, lend, "asset-win", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the migrated permanent (nil) grant is removed; a single time window remains
  gallagher.untils_for("ch-legacy", "gallagher-group1").should eq([lend])
  gallagher.from_for("ch-legacy", "gallagher-group1", lend).should eq(lstart - 45_i64 * 60)

  # ===========================================================
  # Test 30: group resolution is by FEATURE, not zone. A space sitting in
  # zone-level-B1 but carrying the "Secure Basement" feature maps to that
  # feature's group (group3) — proving parking_areas keys are matched against
  # space.features. (Under the old zone-based logic the space's zones would not
  # match any parking_areas key, so the user would get no access at all.)
  # ===========================================================

  settings(win_settings) # feature-based parking_areas, 45m margin
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  feature_space = [
    {
      id: "asset-feat", identifier: "FEAT",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"], # zone says B1...
      features: ["carpriority", "Secure Basement"],               # ...feature says Secure Basement
      notes: "Car", security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(feature_space.to_json)
  gallagher.set_cardholder("feat.user@example.com", "ch-feat")
  calendar.set_groups("feat.user@example.com", default_grp.to_json)

  fstart = now + 3600_i64 * 280
  fend = fstart + 3600_i64
  staff.set_bookings([
    build_booking.call(30001_i64, "feat.user@example.com",
      fstart, fend, "asset-feat", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the "Secure Basement" feature maps to group3 — and ONLY group3 (under the
  # old zone-based mapping the B1 zone would have matched no parking_areas key
  # at all, so the user would have gotten no access)
  gallagher.access_for("ch-feat").should eq(["gallagher-group3"])

  # ===========================================================
  # Test 31: a space whose features resolve to NO gallagher group is EXCLUDED
  # from allocation (even though it is the more-preferred spot) and reported in
  # :spaces_without_groups; the booking lands on the mapped space instead.
  # ===========================================================

  settings(win_settings) # feature-based parking_areas, 45m margin
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  mixed_spaces = [
    {
      # no area feature + no override -> resolves to NO group. "carpriority"
      # makes it the MORE-preferred spot, so picking it would prove a bug.
      id: "asset-unmapped", identifier: "UNMAP",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-mapped", identifier: "MAP",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(mixed_spaces.to_json)
  gallagher.set_cardholder("mix.user@example.com", "ch-mix")
  calendar.set_groups("mix.user@example.com", default_grp.to_json)

  xstart = now + 3600_i64 * 300
  xend = xstart + 3600_i64
  staff.set_bookings([
    build_booking.call(31001_i64, "mix.user@example.com",
      xstart, xend, "unallocated-31001", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # allocated to the MAPPED space, not the (more preferred) unmapped one
  staff.last_update_for(31001_i64).should eq("asset-mapped")
  gallagher.access_for("ch-mix").should contain("gallagher-group1")
  # the unmapped space is reported
  reported = status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }
  reported.should contain("asset-unmapped")
  reported.should_not contain("asset-mapped")
  status[:spaces_without_group_count].as_i.should eq(1)

  # ===========================================================
  # Test 32: when the ONLY compatible space is unmapped, nothing is allocated
  # (the booking goes to the wait list) and the space is reported.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  only_unmapped = [
    {
      id: "asset-only-unmapped", identifier: "ONLY",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(only_unmapped.to_json)
  gallagher.set_cardholder("wl.user@example.com", "ch-wl")
  calendar.set_groups("wl.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(32001_i64, "wl.user@example.com",
      now + 3600_i64 * 320, now + 3600_i64 * 321, "unallocated-32001", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(32001_i64).should be_nil
  staff.last_state(32001_i64).should eq("wait_list")
  status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }.should contain("asset-only-unmapped")

  # ===========================================================
  # Test 33: an already-allocated booking on an unmapped space (with no
  # accessible alternative) is moved off it to the wait list + notified, not
  # approved, and the space is reported.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(only_unmapped.to_json)
  gallagher.set_cardholder("bad.user@example.com", "ch-bad")
  calendar.set_groups("bad.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(33001_i64, "bad.user@example.com",
      now + 3600_i64 * 320, now + 3600_i64 * 321, "asset-only-unmapped", false, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.approved.includes?(33001_i64).should eq(false)
  # moved off the inaccessible spot to the wait list and notified
  staff.last_update_for(33001_i64).not_nil!.starts_with?("unallocated-displaced").should eq(true)
  staff.last_state(33001_i64).should eq("wait_list")
  mailer.sent?("bad.user@example.com", "parking_request", "displaced").should eq(true)
  gallagher.access_for("ch-bad").should be_empty
  status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }.should contain("asset-only-unmapped")

  # ===========================================================
  # Test 34: a space whose features map to MULTIPLE distinct groups grants
  # access to ALL of them (fan-out). Two features mapping to the SAME group
  # still yield a single grant for that group (no double-grant). When every
  # space is mapped the :spaces_without_groups report is cleared.
  # ===========================================================

  settings(win_settings.merge({
    parking_areas: {
      "Open Basement"   => "gallagher-group1",
      "Annex"           => "gallagher-group1", # second feature -> same group
      "Secure Basement" => "gallagher-group3",
    },
  }))
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  multigroup_spaces = [
    {
      id: "asset-multi", identifier: "MULTI",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      # two features -> group1 (Open Basement + Annex), one -> group3
      features: ["carpriority", "Open Basement", "Annex", "Secure Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(multigroup_spaces.to_json)
  gallagher.set_cardholder("mg.user@example.com", "ch-mg")
  calendar.set_groups("mg.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(34001_i64, "mg.user@example.com",
      now + 3600_i64 * 340, now + 3600_i64 * 341, "asset-multi", true, ext_car),
  ].to_json)

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # access granted to BOTH mapped groups (fan-out)
  gallagher.access_for("ch-mg").sort.should eq(["gallagher-group1", "gallagher-group3"])
  # the two features mapping to group1 yield exactly ONE group1 grant
  gallagher.membership_count("ch-mg", "gallagher-group1").should eq(1)
  gallagher.membership_count("ch-mg", "gallagher-group3").should eq(1)
  # every space is mapped now, so the report is cleared
  status[:spaces_without_group_count].as_i.should eq(0)
  status[:spaces_without_groups].as_a.should be_empty

  # ===========================================================
  # Test 35: a permanently-assigned space with no gallagher group is reported
  # (assigned spaces are not allocated, so they're not "excluded", but the
  # misconfiguration is still surfaced) and the assignee gets no access.
  # ===========================================================

  settings(win_settings)
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  assigned_unmapped = [
    {
      id: "asset-assigned-unmapped", identifier: "AU",
      assigned_to: "au.user@example.com", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority"], notes: "Car", # no area feature -> no group
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(assigned_unmapped.to_json)
  gallagher.set_cardholder("au.user@example.com", "ch-au")
  calendar.set_groups("au.user@example.com", default_grp.to_json)
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }.should contain("asset-assigned-unmapped")
  gallagher.access_for("ch-au").should be_empty

  # ===========================================================
  # Test 36: a booking already granted on a space whose mapping has been removed
  # (the space is now unmapped) is moved off it (notified) and re-allocated to
  # another accessible space; its Gallagher access follows the new space's
  # group. Single sweep: the prior grant is seeded into access_granted (and a
  # live Gallagher membership) the way a previous mapped sweep would have left
  # it. (win_settings' parking_areas has no "Temp" key, so asset-temp is
  # unmapped; "Secure Basement" -> group3.)
  # ===========================================================

  tstart = now + 3600_i64 * 360
  tend = tstart + 3600_i64

  settings(win_settings.merge({
    access_granted: {
      "gallagher-group1" => {
        "trans.user@example.com|#{tend}" => {
          email:         "trans.user@example.com",
          cardholder_id: "ch-trans",
          until_unix:    tend,
        },
      },
    },
  }))
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("trans.user@example.com", "ch-trans")
  calendar.set_groups("trans.user@example.com", default_grp.to_json)
  # the prior grant's live Gallagher membership (group1, window ending tend)
  gallagher.zone_access_add_member("gallagher-group1", "ch-trans", tstart - 45_i64 * 60, tend)

  trans_spaces = [
    {
      id: "asset-temp", identifier: "TEMP",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Temp"], notes: "Car", # "Temp" not in parking_areas -> unmapped
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-spare", identifier: "SPARE",
      assigned_to: "", zones: ["zone-building", "zone-level-B3"],
      features: ["Secure Basement"], notes: "Car", # -> group3, kept free
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(trans_spaces.to_json)
  staff.set_bookings([
    build_booking.call(36001_i64, "trans.user@example.com",
      tstart, tend, "asset-temp", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # moved off the now-unmapped asset-temp and re-allocated to spare — because it
  # landed a new space the same run, the displaced email is suppressed (the
  # approval email for the new space covers it)
  mailer.sent?("trans.user@example.com", "parking_request", "displaced").should eq(false)
  staff.last_update_for(36001_i64).should eq("asset-spare")
  staff.approved.includes?(36001_i64).should eq(true)
  # access followed the move: group1 (old spot) removed, group3 (new spot) added
  gallagher.access_for("ch-trans").should eq(["gallagher-group3"])
  status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }.should contain("asset-temp")

  # ===========================================================
  # Test 37: zone priority is PRIMARY, height is the tie-breaker. A 1.95m
  # booking has a 1.95m space free in the less-preferred zone AND a 2.1m space
  # free in the preferred zone. The preferred-zone 2.1m space wins — zone beats
  # the closer height fit (user priority -> zone -> height).
  # ===========================================================

  settings(win_settings)
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  height_spaces = [
    {
      # exact height fit but in the less-preferred zone (shared idx 1); listed first
      id: "asset-h195", identifier: "H195",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "shared", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      # taller but in the more-preferred zone (carpriority idx 0)
      id: "asset-h210", identifier: "H210",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 2.1m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(height_spaces.to_json)
  gallagher.set_cardholder("h.user@example.com", "ch-h")
  calendar.set_groups("h.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(37001_i64, "h.user@example.com",
      now + 3600_i64 * 380, now + 3600_i64 * 381, "unallocated-37001", false, ext_h195),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # preferred zone wins even though the other space is a closer height fit
  staff.last_update_for(37001_i64).should eq("asset-h210")

  # ===========================================================
  # Test 38: a height booking still matches a TALLER space when no exact fit is
  # free (equal-or-greater matching).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  only_tall = [
    {
      id: "asset-only210", identifier: "ONLY210",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 2.1m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(only_tall.to_json)
  gallagher.set_cardholder("t.user@example.com", "ch-t")
  calendar.set_groups("t.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(38001_i64, "t.user@example.com",
      now + 3600_i64 * 400, now + 3600_i64 * 401, "unallocated-38001", false, ext_h195),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the 1.95m booking fits the taller 2.1m space
  staff.last_update_for(38001_i64).should eq("asset-only210")

  # ===========================================================
  # Test 39: a space SHORTER than the required height is not a match — a 2.1m
  # vehicle can't use a 1.95m space, so it goes to the wait list.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  only_short = [
    {
      id: "asset-only195", identifier: "ONLY195",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(only_short.to_json)
  gallagher.set_cardholder("s.user@example.com", "ch-s")
  calendar.set_groups("s.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(39001_i64, "s.user@example.com",
      now + 3600_i64 * 420, now + 3600_i64 * 421, "unallocated-39001", false, ext_h210),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(39001_i64).should be_nil
  staff.last_state(39001_i64).should eq("wait_list")

  # ===========================================================
  # Test 40: a standard (non-restricted) car also prefers the SMALLEST height
  # within its zone, keeping taller spaces free for taller vehicles. Two
  # carpriority spaces (2.1m listed first, 1.95m second) -> the 1.95m wins.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  std_spaces = [
    {
      id: "asset-tall", identifier: "TALL",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 2.1m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-short", identifier: "SHORT",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(std_spaces.to_json)
  gallagher.set_cardholder("std.user@example.com", "ch-std")
  calendar.set_groups("std.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(40001_i64, "std.user@example.com",
      now + 3600_i64 * 440, now + 3600_i64 * 441, "unallocated-40001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # standard car takes the shorter space, leaving the 2.1m space for taller vehicles
  staff.last_update_for(40001_i64).should eq("asset-short")

  # ===========================================================
  # Test 41: template_fields generates ONE approval template per Gallagher group
  # referenced by parking_areas. Two features mapping to the same group collapse
  # to a single template whose description is prefixed with the FIRST matching
  # feature name.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "VIP Basement"    => "gallagher-group1", # same group as Open Basement
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  templates = JSON.parse(exec(:template_fields).get.to_json).as_a
  approved = templates.select { |t| t["trigger"].as_a[1].as_s.starts_with?("approved_") }

  # one template per UNIQUE group (the two group1 features collapse to one),
  # in parking_areas insertion order
  approved.map { |t| t["trigger"].as_a[1].as_s }.should eq([
    "approved_gallagher-group1", "approved_gallagher-group3",
  ])

  # description + name prefixed with the FIRST feature mapping to group1
  g1 = approved.find { |t| t["trigger"].as_a[1].as_s == "approved_gallagher-group1" }.not_nil!
  g1["name"].as_s.should eq("Parking Approved - Open Basement")
  g1["description"].as_s.should eq(
    "Approval for Open Basement - Notifies the recipient that their parking is approved and access has been granted")

  g3 = approved.find { |t| t["trigger"].as_a[1].as_s == "approved_gallagher-group3" }.not_nil!
  g3["description"].as_s.should eq(
    "Approval for Secure Basement - Notifies the recipient that their parking is approved and access has been granted")

  # the generic approval template is always advertised (override fallback) and
  # the non-approval templates are still present
  other_triggers = templates.map { |t| t["trigger"].as_a[1].as_s }
  other_triggers.should contain("approved")
  other_triggers.should contain("wait_list")
  other_triggers.should contain("no_card")

  # ===========================================================
  # Test 42: a space spanning MULTIPLE parking areas picks the approval template
  # by parking_areas CONFIGURATION order (deterministic), not by the order the
  # features happen to appear on the asset. Access is still granted to all areas.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  multi_area = [
    {
      id: "asset-multi", identifier: "MULTI",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      # Mezzanine (group2) listed BEFORE Open Basement (group1); config order
      # privileges Open Basement, so the email must key to group1
      features: ["Mezzanine", "Open Basement", "carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(multi_area.to_json)
  gallagher.set_cardholder("multi.user@example.com", "ch-multi")
  calendar.set_groups("multi.user@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(42001_i64, "multi.user@example.com",
      now + 3600_i64 * 460, now + 3600_i64 * 461, "unallocated-42001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(42001_i64).should eq("asset-multi")
  # access granted to BOTH mapped areas
  access = gallagher.access_for("ch-multi")
  access.should contain("gallagher-group1")
  access.should contain("gallagher-group2")
  # but the approval email keys to the config-order-first area (Open Basement)
  mailer.last_template.should eq(["parking_request", "approved_gallagher-group1"])

  # ===========================================================
  # Test 43: a space holding MULTIPLE bookings (different days) must be busy for
  # a new booking overlapping ANY of them — not just the last one tracked.
  # b1 (Mon) and b2 (Tue) both hold the space; a same-priority booking
  # overlapping b1 must NOT be allocated on top (production clash bug).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  calendar.set_groups("clash.user@example.com", default_grp.to_json)
  gallagher.set_cardholder("clash.user@example.com", "ch-clash")

  solo_space = [
    {
      id: "asset-solo", identifier: "SOLO",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(solo_space.to_json)

  mon_start = now + 3600_i64 * 470
  mon_end = now + 3600_i64 * 471
  tue_start = now + 3600_i64 * 494
  tue_end = now + 3600_i64 * 495

  staff.set_bookings([
    build_booking.call(43001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true, ext_car),
    build_booking.call(43002_i64, "normal.user@example.com",
      tue_start, tue_end, "asset-solo", true, ext_car),
    build_booking.call(43003_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-43003", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the overlapping booking must be wait-listed, NOT allocated over b1
  staff.last_update_for(43003_i64).should be_nil
  staff.last_state(43003_i64).should eq("wait_list")
  # the existing bookings keep the space (no displacement at equal priority)
  staff.last_update_for(43001_i64).should be_nil
  staff.last_update_for(43002_i64).should be_nil
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)

  # ===========================================================
  # Test 44: preemption must displace the OVERLAPPING occupant even when the
  # space also holds other (non-overlapping) bookings — and the displacement
  # must complete before the higher-priority booking is allocated.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)

  staff.set_bookings([
    build_booking.call(44001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true, ext_car),
    build_booking.call(44002_i64, "normal.user@example.com",
      tue_start, tue_end, "asset-solo", true, ext_car),
    build_booking.call(44003_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-44003", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the overlapping lower-priority occupant was moved off FIRST (and, with no
  # space to land, gets the displaced email — with the preemption reason)
  staff.last_update_for(44001_i64).should eq("unallocated-displaced-44001")
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(true)
  mailer.arg_for("normal.user@example.com", "parking_request", "displaced", "reason")
    .should eq("The parking space was reassigned to a higher priority booking.")
  # then the higher-priority booking took the space
  staff.last_update_for(44003_i64).should eq("asset-solo")
  # the non-overlapping Tuesday booking is untouched
  staff.last_update_for(44002_i64).should be_nil

  # ===========================================================
  # Test 45: if the displacement FAILS (staff API error) the space is still
  # held — the higher-priority booking must NOT be allocated on top of it.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)
  staff.fail_update_for(45001_i64)

  staff.set_bookings([
    build_booking.call(45001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true, ext_car),
    build_booking.call(45002_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-45002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # displacement failed -> occupant keeps the space, no displaced email
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)
  # the higher-priority booking is wait-listed instead of double-booked
  staff.last_update_for(45002_i64).should be_nil
  staff.last_state(45002_i64).should eq("wait_list")

  # ===========================================================
  # Test 46: a FAILED allocate (staff API rejects the update) must not leave the
  # local booking claiming the space — no approval and no Gallagher access.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)
  staff.fail_update_for(46001_i64)

  staff.set_bookings([
    build_booking.call(46001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-46001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.approved.includes?(46001_i64).should eq(false)
  mailer.sent?("clash.user@example.com", "parking_request", "approved_gallagher-group1").should eq(false)
  # no access granted for a space the booking never got
  gallagher.access_for("ch-clash").should eq([] of String)

  # ===========================================================
  # Test 47: a REJECTED booking still carrying an asset id does not occupy the
  # space — a new overlapping booking is allocated onto it and the rejected
  # user is never "displaced" or emailed.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)

  rejected_booking = {
    id:              47001_i64,
    booking_type:    "parking",
    booking_start:   mon_start,
    booking_end:     mon_end,
    asset_id:        "asset-solo",
    asset_ids:       ["asset-solo"],
    user_id:         "user-47001",
    user_email:      "normal.user@example.com",
    user_name:       "normal.user@example.com",
    booked_by_email: "normal.user@example.com",
    booked_by_name:  "normal.user@example.com",
    zones:           ["zone-building"],
    created:         now - 1000_i64 + 47001_i64,
    approved:        true,
    rejected:        true,
    deleted:         false,
    extension_data:  ext_car,
  }
  staff.set_bookings([
    rejected_booking,
    build_booking.call(47002_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-47002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the space is free despite the rejected booking's asset id
  staff.last_update_for(47002_i64).should eq("asset-solo")
  # the rejected booking is untouched: not displaced, no email
  staff.last_update_for(47001_i64).should be_nil
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)

  # ===========================================================
  # Test 48: preemption commits before notifying — when the preemptor's own
  # allocate FAILS after the occupant was moved off, the occupant is restored
  # to the space and never receives a displaced email (no email churn).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)
  staff.fail_update_for(48002_i64)

  staff.set_bookings([
    build_booking.call(48001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true, ext_car),
    build_booking.call(48002_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-48002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the occupant was rolled back onto the space, with no displaced email
  staff.last_update_for(48001_i64).should eq("asset-solo")
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)
  # the preemptor is wait-listed, not double-booked
  staff.last_update_for(48002_i64).should be_nil
  staff.last_state(48002_i64).should eq("wait_list")

  # ===========================================================
  # Test 49: with MULTIPLE overlapping occupants, a failed displacement stops
  # the preemption immediately — later occupants are never touched.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)
  staff.fail_update_for(49001_i64)

  staff.set_bookings([
    build_booking.call(49001_i64, "normal.user@example.com",
      mon_start, mon_start + 3600_i64, "asset-solo", true, ext_car),
    build_booking.call(49002_i64, "normal.user@example.com",
      mon_start + 3600_i64, mon_start + 7200_i64, "asset-solo", true, ext_car),
    build_booking.call(49003_i64, "priority.user@example.com",
      mon_start, mon_start + 7200_i64, "unallocated-49003", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # first displacement failed -> the second occupant was never displaced
  staff.last_update_for(49002_i64).should be_nil
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)
  # the preemptor is wait-listed
  staff.last_update_for(49003_i64).should be_nil
  staff.last_state(49003_i64).should eq("wait_list")

  # helper to build a recurring booking instance (same id, per-instance window)
  build_instance = ->(id : Int64, instance : Int64, user : String, starting : Int64, ending : Int64, asset_id : String, approved : Bool) do
    {
      id:              id,
      instance:        instance,
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
      extension_data:  ext_car,
    }
  end

  # ===========================================================
  # Test 50: a RECURRING booking expands to several instances all holding the
  # parent's space (different days). A new booking overlapping ANY instance must
  # be wait-listed — the exact production clash shape.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)

  staff.set_bookings([
    build_instance.call(50001_i64, mon_start, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true),
    build_instance.call(50001_i64, tue_start, "normal.user@example.com",
      tue_start, tue_end, "asset-solo", true),
    build_booking.call(50002_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-50002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the booking overlapping the Monday instance is wait-listed, not double-booked
  staff.last_update_for(50002_i64).should be_nil
  staff.last_state(50002_i64).should eq("wait_list")
  # the recurring series keeps the space
  staff.last_update_for(50001_i64).should be_nil

  # ===========================================================
  # Test 51: recurring instances are allocated INDEPENDENTLY — each day's
  # instance gets its own per-instance asset update (booking_instances persist
  # asset overrides), so a series can split across spaces when one space is
  # busy on one of its days.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  two_spaces = [
    solo_space[0],
    {
      id: "asset-solo2", identifier: "SOLO2",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(two_spaces.to_json)

  staff.set_bookings([
    # asset-solo is taken on Tuesday only
    build_booking.call(51000_i64, "normal.user@example.com",
      tue_start, tue_end, "asset-solo", true, ext_car),
    # recurring series needing Monday AND Tuesday
    build_instance.call(51001_i64, mon_start, "clash.user@example.com",
      mon_start, mon_end, "unallocated-51001", false),
    build_instance.call(51001_i64, tue_start, "clash.user@example.com",
      tue_start, tue_end, "unallocated-51001", false),
    # same-priority booking created later, overlapping Tuesday: both spaces are
    # then busy on Tuesday -> wait list
    build_booking.call(51002_i64, "normal.user@example.com",
      tue_start, tue_end, "unallocated-51002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # Monday instance takes the preferred space (free on Monday); the Tuesday
  # instance splits onto the other space — each via its OWN instance update
  staff.update_for(51001_i64, mon_start).should eq("asset-solo")
  staff.update_for(51001_i64, tue_start).should eq("asset-solo2")
  # approval is persisted per instance too
  staff.approved_instance?(51001_i64, mon_start).should eq(true)
  staff.approved_instance?(51001_i64, tue_start).should eq(true)

  # the instances' windows block the later booking from both spaces
  staff.last_update_for(51002_i64).should be_nil
  staff.last_state(51002_i64).should eq("wait_list")

  # ===========================================================
  # Test 52: preemption displaces ONLY the overlapping instance of a recurring
  # occupant — the other day's instance keeps its space and state.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)

  staff.set_bookings([
    build_instance.call(52001_i64, mon_start, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true),
    build_instance.call(52001_i64, tue_start, "normal.user@example.com",
      tue_start, tue_end, "asset-solo", true),
    build_booking.call(52002_i64, "priority.user@example.com",
      tue_start, tue_end, "unallocated-52002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # only the Tuesday instance was displaced, via a per-instance update
  staff.update_for(52001_i64, tue_start).should eq("unallocated-displaced-52001")
  staff.update_for(52001_i64, mon_start).should be_nil
  # Tuesday's process_state reset; Monday keeps its access_granted state
  staff.last_state(52001_i64, tue_start).should eq("wait_list")
  staff.last_state(52001_i64, mon_start).should eq("access_granted_emailed")
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(true)
  # the higher-priority booking took the space for Tuesday
  staff.last_update_for(52002_i64).should eq("asset-solo")

  # ===========================================================
  # Test 53: allow_displacement: false disables preemption — a higher priority
  # booking waits for a free space instead of bumping the occupant.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: false,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json)

  staff.set_bookings([
    build_booking.call(53001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-solo", true, ext_car),
    build_booking.call(53002_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-53002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the occupant keeps the space: no displacement, no displaced email
  staff.last_update_for(53001_i64).should be_nil
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)
  # the higher priority booking is wait-listed instead
  staff.last_update_for(53002_i64).should be_nil
  staff.last_state(53002_i64).should eq("wait_list")

  # ===========================================================
  # Test 54: allow_displacement: false also keeps a booking on a space that has
  # no gallagher mapping — it is reported but the user is not moved.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  ghost_space = [
    {
      id: "asset-ghost", identifier: "GHOST",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      # "Mystery Zone" is not a parking_areas key and there is no
      # security_system_groups override -> no gallagher group resolvable
      features: ["Mystery Zone", "carpriority"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(ghost_space.to_json)

  staff.set_bookings([
    build_booking.call(54001_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-ghost", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # reported as misconfigured, but the booking is NOT moved off the space
  status[:spaces_without_groups].as_a.map { |s| s["id"].as_s }.should contain("asset-ghost")
  staff.last_update_for(54001_i64).should be_nil
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)

  # ===========================================================
  # Test 55: an ACROD request with all ACROD spaces taken falls back to a
  # regular space instead of being wait-listed.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  fallback_spaces = [
    {
      id: "asset-acrod_x", identifier: "AX",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["ACROD", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    solo_space[0], # regular: carpriority + Open Basement
  ]
  staff.set_assets(fallback_spaces.to_json)

  staff.set_bookings([
    # the only ACROD space is already taken for the window
    build_booking.call(55000_i64, "acrod.user@example.com",
      mon_start, mon_end, "asset-acrod_x", true, ext_acrod),
    build_booking.call(55001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-55001", false, ext_acrod),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the restriction is dropped and a regular space provided
  staff.last_update_for(55001_i64).should eq("asset-solo")
  staff.approved.includes?(55001_i64).should eq(true)
  # the existing ACROD allocation is untouched
  staff.last_update_for(55000_i64).should be_nil

  # ===========================================================
  # Test 56: an ACROD request when NO ACROD spaces exist at all also falls back
  # to a regular space.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(solo_space.to_json) # only the regular space

  staff.set_bookings([
    build_booking.call(56001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-56001", false, ext_acrod),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(56001_i64).should eq("asset-solo")
  staff.last_state(56001_i64).should eq("access_granted_emailed")

  # ===========================================================
  # Test 57: height requirements NEVER fall back — when the only fitting space
  # is taken, the booking is wait-listed even though shorter and regular spaces
  # are free.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  height_fallback_spaces = [
    {
      id: "asset-tall210x", identifier: "T210X",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 2.1m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-short195x", identifier: "S195X",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["Max height 1.95m", "carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    solo_space[0], # regular space with no height indicator
  ]
  staff.set_assets(height_fallback_spaces.to_json)

  staff.set_bookings([
    # the only space fitting a 2.1m vehicle is taken (same priority -> no preempt)
    build_booking.call(57000_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-tall210x", true, ext_car),
    build_booking.call(57001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-57001", false, ext_h210),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # no fallback to the shorter or regular space — wait-listed
  staff.last_update_for(57001_i64).should be_nil
  staff.last_state(57001_i64).should eq("wait_list")

  # ===========================================================
  # Test 58: a space that looks free to the driver but is booked server-side
  # (clash / 409) is skipped — the booking lands on the next free space instead
  # of failing. (Our busy view is zone-scoped + capped, so this can happen.)
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  two_regular = [
    {
      id: "asset-r1", identifier: "R1",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-r2", identifier: "R2",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(two_regular.to_json)
  # the preferred space is booked outside the driver's view
  staff.clash_update_for(58001_i64, "asset-r1")

  staff.set_bookings([
    build_booking.call(58001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-58001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # skipped the clashing space, allocated to the next free one
  staff.last_update_for(58001_i64).should eq("asset-r2")
  staff.approved.includes?(58001_i64).should eq(true)
  gallagher.access_for("ch-clash").should contain("gallagher-group1")

  # ===========================================================
  # Test 59: when the only free space clashes server-side, the booking is
  # wait-listed (not crashed, no access granted).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # only asset-r1
  staff.clash_update_for(59001_i64, "asset-r1")

  staff.set_bookings([
    build_booking.call(59001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-59001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(59001_i64).should be_nil
  staff.last_state(59001_i64).should eq("wait_list")
  gallagher.access_for("ch-clash").should eq([] of String)

  # ===========================================================
  # Test 60: the production scenario — an ACROD request falls back to a regular
  # space that is booked server-side. The clash is handled gracefully (the
  # booking is wait-listed) instead of erroring on a clashing allocation.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # only a regular space, no ACROD
  staff.clash_update_for(60001_i64, "asset-r1")

  staff.set_bookings([
    build_booking.call(60001_i64, "clash.user@example.com",
      mon_start, mon_end, "unallocated-60001", false, ext_acrod),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # fell back to the regular space, hit the server clash, wait-listed cleanly
  staff.last_update_for(60001_i64).should be_nil
  staff.last_state(60001_i64).should eq("wait_list")

  # ===========================================================
  # Test 61: a space that clashes server-side during preemption is not targeted
  # again by later bookings — the displaced occupant isn't churned in and out
  # repeatedly. Two higher-priority bookings contend for one space held by a
  # lower-priority booking, but the space rejects every allocation.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # only asset-r1
  # asset-r1 is booked server-side for the preemptors (invisible to the driver)
  staff.clash_update_for(61001_i64, "asset-r1")
  staff.clash_update_for(61002_i64, "asset-r1")

  staff.set_bookings([
    # low priority occupant holds the space
    build_booking.call(61000_i64, "normal.user@example.com",
      mon_start, mon_end, "asset-r1", true, ext_car),
    # two higher priority bookings both want it
    build_booking.call(61001_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-61001", false, ext_car),
    build_booking.call(61002_i64, "priority.user@example.com",
      mon_start, mon_end, "unallocated-61002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the occupant was displaced + restored exactly once (by the first preemptor);
  # the second preemptor saw the space as occupied and didn't churn it again
  staff.update_count_for(61000_i64).should eq(2)
  staff.last_update_for(61000_i64).should eq("asset-r1")
  # the occupant kept its space, never notified of a (rolled-back) displacement
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(false)
  # both preemptors are wait-listed (the space genuinely wasn't free)
  staff.last_update_for(61001_i64).should be_nil
  staff.last_update_for(61002_i64).should be_nil
  staff.last_state(61001_i64).should eq("wait_list")
  staff.last_state(61002_i64).should eq("wait_list")

  # ===========================================================
  # Test 62: a user with several unprocessed bookings on different days gets an
  # approval email for EACH booking — they are independent bookings, deduped
  # only per-booking, so there is no cross-booking suppression.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # one space, reused across days

  staff.set_bookings([
    build_booking.call(62001_i64, "multi.day@example.com",
      mon_start, mon_end, "unallocated-62001", false, ext_car),
    build_booking.call(62002_i64, "multi.day@example.com",
      tue_start, tue_end, "unallocated-62002", false, ext_car),
  ].to_json)
  gallagher.set_cardholder("multi.day@example.com", "ch-multiday")
  calendar.set_groups("multi.day@example.com", default_grp.to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # both days allocated to the space (non-overlapping windows) and approved
  staff.last_update_for(62001_i64).should eq("asset-r1")
  staff.last_update_for(62002_i64).should eq("asset-r1")
  staff.last_state(62001_i64).should eq("access_granted_emailed")
  staff.last_state(62002_i64).should eq("access_granted_emailed")
  # one approval email PER booking (asset-r1 -> Open Basement -> group1)
  mailer.times_sent("multi.day@example.com", "parking_request", "approved_gallagher-group1").should eq(2)

  # ===========================================================
  # Test 63: a failed approval-email send does NOT advance the booking past
  # "access_granted" — the next pass retries the email (without re-granting) and
  # the user is emailed exactly once across the two attempts.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("retry.user@example.com", "ch-retry")
  calendar.set_groups("retry.user@example.com", default_grp.to_json)

  # a booking already allocated + approved, access granted but email not yet sent
  granted_pending = {
    id:              63001_i64,
    booking_type:    "parking",
    booking_start:   mon_start,
    booking_end:     mon_end,
    asset_id:        "asset-r1",
    asset_ids:       ["asset-r1"],
    user_id:         "user-63001",
    user_email:      "retry.user@example.com",
    user_name:       "retry.user@example.com",
    booked_by_email: "retry.user@example.com",
    booked_by_name:  "retry.user@example.com",
    zones:           ["zone-building"],
    created:         now - 1000_i64 + 63001_i64,
    approved:        true,
    rejected:        false,
    deleted:         false,
    process_state:   "access_granted",
    extension_data:  ext_car,
  }
  staff.set_bookings([granted_pending].to_json)

  # sweep 1: the mailer is down -> the email send fails
  mailer.set_fail_send(true)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # not emailed, and the state was NOT advanced (no booking_state write)
  mailer.times_sent("retry.user@example.com", "parking_request", "approved_gallagher-group1").should eq(0)
  staff.last_state(63001_i64).should be_nil

  # sweep 2: the mailer recovers -> the email is retried and succeeds
  mailer.set_fail_send(false)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_state(63001_i64).should eq("access_granted_emailed")
  mailer.times_sent("retry.user@example.com", "parking_request", "approved_gallagher-group1").should eq(1)

  # ===========================================================
  # Test 64: when the staff API bookings query fails, the run ABORTS and leaves
  # existing Gallagher access untouched — it must NOT treat the failure as "no
  # bookings" and revoke everyone's access.
  # ===========================================================

  ab_until = now + 3600_i64 * 500

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    # a grant the driver previously made + tracked
    access_granted: {
      "gallagher-group1" => {
        "abort.user@example.com|#{ab_until}" => {
          email:         "abort.user@example.com",
          cardholder_id: "ch-abort",
          until_unix:    ab_until,
        },
      },
    },
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("abort.user@example.com", "ch-abort")
  # the live Gallagher membership matching the seeded grant
  gallagher.zone_access_add_member("gallagher-group1", "ch-abort", ab_until - 1800_i64, ab_until)

  # the staff API bookings query errors this sweep
  staff.set_fail_query(true)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the run aborted cleanly: the existing grant was NOT revoked...
  gallagher.access_for("ch-abort").should contain("gallagher-group1")
  # ...and no allocation work happened
  staff.approved.empty?.should eq(true)

  # next sweep (staff API recovered) reconciles normally — with no bookings the
  # now-expired tracked grant is cleaned up as usual
  staff.set_fail_query(false)
  staff.set_bookings("[]")
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  gallagher.access_for("ch-abort").should_not contain("gallagher-group1")

  # ===========================================================
  # Test 65: the (expensive) Gallagher cardholder lookup is cached across
  # sweeps — it runs once per user, not on every sweep.
  # ===========================================================

  staff.set_fail_query(false)
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("cached.user@example.com", "ch-cached")
  calendar.set_groups("cached.user@example.com", default_grp.to_json)

  cached_booking = [
    build_booking.call(65001_i64, "cached.user@example.com",
      mon_start, mon_end, "unallocated-65001", false, ext_car),
  ].to_json

  # two sweeps for the same user — no settings() change between them (which
  # would otherwise flush the cache)
  staff.set_bookings(cached_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  staff.set_bookings(cached_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the cardholder lookup ran exactly once despite two sweeps (and multiple
  # internal resolutions per sweep)
  gallagher.lookup_count("cached.user@example.com").should eq(1)

  # ===========================================================
  # Test 66: changing the lookup MECHANISM (gallagher_id_field) flushes the
  # cache, so the user is re-resolved through the new field rather than served
  # a stale cardholder id.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  # with no id field, the user resolves by email to ch-old
  gallagher.set_cardholder("flip.user@example.com", "ch-old")
  calendar.set_groups("flip.user@example.com", default_grp.to_json)

  flip_booking = [
    build_booking.call(66001_i64, "flip.user@example.com",
      mon_start, mon_end, "unallocated-66001", false, ext_car),
  ].to_json
  staff.set_bookings(flip_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  gallagher.access_for("ch-old").should contain("gallagher-group1")

  # switch to directory-resolved lookups: the SAME email now resolves (via
  # employeeId) to a different cardholder. The cache must flush so the new
  # cardholder is used.
  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    gallagher_id_field: "employeeId",
  })
  sleep 100.milliseconds

  calendar.set_user_employee_id("flip.user@example.com", "EMP-NEW")
  gallagher.set_cardholder("EMP-NEW", "ch-new")
  staff.set_bookings(flip_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # re-resolved through the new field to the new cardholder (cache was flushed)
  gallagher.access_for("ch-new").should contain("gallagher-group1")

  # ===========================================================
  # Test 67: the user priority (AD group) lookup is cached across sweeps — the
  # expensive directory group lookup runs once per user, not every sweep.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("prio.user@example.com", "ch-prio")
  calendar.set_groups("prio.user@example.com", [{id: "group-default", email: "default@grp.com"}].to_json)

  prio_booking = [
    build_booking.call(67001_i64, "prio.user@example.com",
      mon_start, mon_end, "unallocated-67001", false, ext_car),
  ].to_json

  # two sweeps for the same user — no settings() change between them
  staff.set_bookings(prio_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  staff.set_bookings(prio_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the directory group lookup ran exactly once despite two sweeps
  calendar.group_lookup_count("prio.user@example.com").should eq(1)

  # ===========================================================
  # Test 68: changing auto_approval_groups flushes the priority cache, so users
  # are re-evaluated against the new groups rather than served a stale priority.
  # ===========================================================

  settings({
    poll_rate: 999_999,
    # a different priority-group list invalidates cached priorities
    auto_approval_groups:            ["group-vip", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.set_bookings(prio_booking)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the cache was flushed on the settings change, so the user was looked up again
  calendar.group_lookup_count("prio.user@example.com").should eq(2)

  # ===========================================================
  # Test 69: a booking on a space that is no longer bookable (e.g. taken out of
  # service) is displaced and re-allocated to a free bookable space.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: true,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("broken.user@example.com", "ch-broken")
  calendar.set_groups("broken.user@example.com", default_grp.to_json)

  oos_spaces = [
    {
      # mapped (group1) but taken OUT OF SERVICE
      id: "asset-broken", identifier: "BROKEN",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: false,
    },
    {
      id: "asset-good", identifier: "GOOD",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(oos_spaces.to_json)

  staff.set_bookings([
    build_booking.call(69001_i64, "broken.user@example.com",
      mon_start, mon_end, "asset-broken", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # moved off the out-of-service space and re-allocated to the free one; the
  # displaced email is suppressed because the booking immediately landed a new
  # space (the approval email covers it)
  staff.last_update_for(69001_i64).should eq("asset-good")
  mailer.sent?("broken.user@example.com", "parking_request", "displaced").should eq(false)
  gallagher.access_for("ch-broken").should contain("gallagher-group1")

  # ===========================================================
  # Test 70: a booking on a non-bookable space is displaced EVEN when
  # allow_displacement is false — the space is gone, this is a forced move, not
  # a preemption.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: false,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("broken.user@example.com", "ch-broken")
  calendar.set_groups("broken.user@example.com", default_grp.to_json)
  staff.set_assets(oos_spaces.to_json)

  staff.set_bookings([
    build_booking.call(70001_i64, "broken.user@example.com",
      mon_start, mon_end, "asset-broken", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # forced off the out-of-service space and re-allocated despite displacement
  # being disabled (that policy only governs preemption of lower-priority users)
  staff.last_update_for(70001_i64).should eq("asset-good")
  # re-allocated immediately, so no displaced email
  mailer.sent?("broken.user@example.com", "parking_request", "displaced").should eq(false)
  gallagher.access_for("ch-broken").should contain("gallagher-group1")

  # ===========================================================
  # Test 71: a booking on a non-bookable space with NO free space to move to is
  # still vacated (moved off) and wait-listed — even with displacement disabled.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("broken.user@example.com", "ch-broken")
  calendar.set_groups("broken.user@example.com", default_grp.to_json)
  # only the broken space exists
  staff.set_assets([oos_spaces[0]].to_json)

  staff.set_bookings([
    build_booking.call(71001_i64, "broken.user@example.com",
      mon_start, mon_end, "asset-broken", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # vacated (moved to the displaced placeholder) and wait-listed; the user no
  # longer holds the out-of-service space. With no space to land, the displaced
  # email IS sent — carrying the reason for the move.
  staff.last_update_for(71001_i64).should eq("unallocated-displaced-71001")
  staff.last_state(71001_i64).should eq("wait_list")
  mailer.sent?("broken.user@example.com", "parking_request", "displaced").should eq(true)
  mailer.arg_for("broken.user@example.com", "parking_request", "displaced", "reason")
    .should eq("The parking space was taken out of service.")
  # no lingering access to the broken space's group from this booking
  gallagher.access_for("ch-broken").should eq([] of String)

  # ===========================================================
  # Test 72: a user previously on the no-card list who has since been issued a
  # card (or simply doesn't book again) is DROPPED from the list — it now
  # reflects the post-run state rather than growing forever. No re-book needed.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    # seed the persisted no-card list with a user who won't book this run
    users_without_cards: ["stale.user@example.com"],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  staff.set_bookings("[]") # stale.user has no booking / no lookup error this run
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # dropped without needing to re-book, and not (re)emailed
  status[:users_without_cards].as_a.map(&.as_s).should_not contain("stale.user@example.com")
  mailer.sent?("stale.user@example.com", "parking_request", "no_card").should eq(false)

  # ===========================================================
  # Test 73: the no-card email carries the reason a cardholder couldn't be
  # resolved.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  # email-based lookup, no cardholder registered -> "no gallagher cardholder found"
  calendar.set_groups("nocard2.user@example.com", default_grp.to_json)
  staff.set_bookings([
    build_booking.call(73001_i64, "nocard2.user@example.com",
      mon_start, mon_end, "unallocated-73001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # withheld and notified, the email carrying the reason
  staff.last_update_for(73001_i64).should be_nil
  mailer.sent?("nocard2.user@example.com", "parking_request", "no_card").should eq(true)
  mailer.arg_for("nocard2.user@example.com", "parking_request", "no_card", "reason")
    .should eq("no gallagher cardholder found")
  status[:users_without_cards].as_a.map(&.as_s).should contain("nocard2.user@example.com")

  # ===========================================================
  # Test 74: displacement_notification_hours gives users notice — a booking
  # starting within the window can't be preempted, so the higher-priority
  # booking waits instead. A booking starting OUTSIDE the window still can be.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 24,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: true,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # one space: asset-r1
  gallagher.set_cardholder("notice.low@example.com", "ch-notice-low")
  gallagher.set_cardholder("notice.high@example.com", "ch-notice-high")
  calendar.set_groups("notice.low@example.com", default_grp.to_json)
  calendar.set_groups("notice.high@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)

  # the occupant starts in 2h — INSIDE the 24h notice window
  soon_start = now + 3600_i64 * 2
  soon_end = soon_start + 3600_i64
  staff.set_bookings([
    build_booking.call(74001_i64, "notice.low@example.com",
      soon_start, soon_end, "asset-r1", true, ext_car),
    build_booking.call(74002_i64, "notice.high@example.com",
      soon_start, soon_end, "unallocated-74002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the occupant keeps the space (too close to its start to be displaced)...
  staff.last_update_for(74001_i64).should be_nil
  mailer.sent?("notice.low@example.com", "parking_request", "displaced").should eq(false)
  # ...and the higher-priority booking waits
  staff.last_update_for(74002_i64).should be_nil
  staff.last_state(74002_i64).should eq("wait_list")

  # --- a booking starting beyond the window CAN still be preempted ---
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("notice.low@example.com", "ch-notice-low")
  gallagher.set_cardholder("notice.high@example.com", "ch-notice-high")
  calendar.set_groups("notice.low@example.com", default_grp.to_json)
  calendar.set_groups("notice.high@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)

  # the occupant starts in 48h — OUTSIDE the 24h notice window
  later_start = now + 3600_i64 * 48
  later_end = later_start + 3600_i64
  staff.set_bookings([
    build_booking.call(74011_i64, "notice.low@example.com",
      later_start, later_end, "asset-r1", true, ext_car),
    build_booking.call(74012_i64, "notice.high@example.com",
      later_start, later_end, "unallocated-74012", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # enough notice -> the occupant is displaced and the high-priority booking wins
  staff.last_update_for(74011_i64).should eq("unallocated-displaced-74011")
  mailer.sent?("notice.low@example.com", "parking_request", "displaced").should eq(true)
  staff.last_update_for(74012_i64).should eq("asset-r1")

  # ===========================================================
  # Test 75: a FORCED move (space out of service) bypasses the notice period —
  # the space is gone, so even a booking starting within the window is moved.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("notice.oos@example.com", "ch-notice-oos")
  calendar.set_groups("notice.oos@example.com", default_grp.to_json)
  forced_spaces = [
    {
      id: "asset-oos", identifier: "OOS",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: false,
    },
    {
      id: "asset-spare-oos", identifier: "SPAREOOS",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(forced_spaces.to_json)

  staff.set_bookings([
    build_booking.call(75001_i64, "notice.oos@example.com",
      soon_start, soon_end, "asset-oos", true, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # moved off the out-of-service space and re-allocated despite the notice window
  staff.last_update_for(75001_i64).should eq("asset-spare-oos")

  # ===========================================================
  # Test 76: with displacement DISABLED, the displacement report still records
  # which displacements WOULD occur (for management review) — without actually
  # bumping anyone.
  # ===========================================================

  report_tz = Time::Location.load("Australia/Sydney")

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: false,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # asset-r1
  gallagher.set_cardholder("report.low@example.com", "ch-report-low")
  gallagher.set_cardholder("report.high@example.com", "ch-report-high")
  calendar.set_groups("report.low@example.com", default_grp.to_json)
  calendar.set_groups("report.high@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)

  rep_start = now + 3600_i64 * 100
  rep_end = rep_start + 3600_i64
  staff.set_bookings([
    build_booking.call(76001_i64, "report.low@example.com",
      rep_start, rep_end, "asset-r1", true, ext_car),
    build_booking.call(76002_i64, "report.high@example.com",
      rep_start, rep_end, "unallocated-76002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # nobody was actually displaced (displacement disabled)
  staff.last_update_for(76001_i64).should be_nil
  staff.last_state(76002_i64).should eq("wait_list")
  mailer.sent?("report.low@example.com", "parking_request", "displaced").should eq(false)

  # ...but the would-be displacement is captured in the report
  report = status[:displacement_report].as_a
  report.size.should eq(1)
  entry = report.first
  # the report uses the space NAME (identifier), not the asset id
  entry["space"].as_s.should eq("R1")
  entry["displaced"].as_s.should eq("report.low@example.com")
  entry["replaced_with"].as_s.should eq("report.high@example.com")
  entry["date"].as_s.should eq(Time.unix(rep_start).in(report_tz).to_s("%d/%m/%Y"))

  # ===========================================================
  # Test 77: with displacement ENABLED, the report records actual displacements,
  # date-sorted (here two bumps on different parking dates).
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: true,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # asset-r1
  gallagher.set_cardholder("rep.low1@example.com", "ch-rl1")
  gallagher.set_cardholder("rep.low2@example.com", "ch-rl2")
  gallagher.set_cardholder("rep.high1@example.com", "ch-rh1")
  gallagher.set_cardholder("rep.high2@example.com", "ch-rh2")
  calendar.set_groups("rep.low1@example.com", default_grp.to_json)
  calendar.set_groups("rep.low2@example.com", default_grp.to_json)
  calendar.set_groups("rep.high1@example.com", [{id: "group-priority", email: "p@grp.com"}].to_json)
  calendar.set_groups("rep.high2@example.com", [{id: "group-priority", email: "p@grp.com"}].to_json)

  day1_start = now + 3600_i64 * 100
  day1_end = day1_start + 3600_i64
  day2_start = day1_start + 86400_i64 * 2 # two days later -> a different date
  day2_end = day2_start + 3600_i64

  # NOTE: the day-2 preemptor (77003) is created BEFORE the day-1 one (77004) so
  # it is processed first and recorded first — the report must re-sort by date.
  staff.set_bookings([
    build_booking.call(77001_i64, "rep.low1@example.com",
      day1_start, day1_end, "asset-r1", true, ext_car),
    build_booking.call(77002_i64, "rep.low2@example.com",
      day2_start, day2_end, "asset-r1", true, ext_car),
    build_booking.call(77003_i64, "rep.high2@example.com",
      day2_start, day2_end, "unallocated-77003", false, ext_car),
    build_booking.call(77004_i64, "rep.high1@example.com",
      day1_start, day1_end, "unallocated-77004", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the higher-priority bookings took the space on each day
  staff.last_update_for(77003_i64).should eq("asset-r1")
  staff.last_update_for(77004_i64).should eq("asset-r1")

  # the report has both displacements, sorted by date
  report2 = status[:displacement_report].as_a
  report2.size.should eq(2)
  report2.map { |e| e["date"].as_s }.should eq([
    Time.unix(day1_start).in(report_tz).to_s("%d/%m/%Y"),
    Time.unix(day2_start).in(report_tz).to_s("%d/%m/%Y"),
  ])
  report2.map { |e| e["displaced"].as_s }.should eq(["rep.low1@example.com", "rep.low2@example.com"])
  report2.map { |e| e["replaced_with"].as_s }.should eq(["rep.high1@example.com", "rep.high2@example.com"])

  # ===========================================================
  # Test 78: with displacement DISABLED and several would-be preemptors, each is
  # reported against a DIFFERENT space — the disabled run simulates the moves in
  # its local view so it doesn't keep reporting the same occupant/space.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    allow_displacement: false,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  cascade_spaces = [
    {
      id: "asset-ca", identifier: "CA",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
    {
      id: "asset-cb", identifier: "CB",
      assigned_to: "", zones: ["zone-building", "zone-level-B1"],
      features: ["carpriority", "Open Basement"], notes: "Car",
      security_system_groups: [] of String, bookable: true,
    },
  ]
  staff.set_assets(cascade_spaces.to_json)
  gallagher.set_cardholder("casc.low1@example.com", "ch-cl1")
  gallagher.set_cardholder("casc.low2@example.com", "ch-cl2")
  gallagher.set_cardholder("casc.high1@example.com", "ch-ch1")
  gallagher.set_cardholder("casc.high2@example.com", "ch-ch2")
  calendar.set_groups("casc.low1@example.com", default_grp.to_json)
  calendar.set_groups("casc.low2@example.com", default_grp.to_json)
  calendar.set_groups("casc.high1@example.com", [{id: "group-priority", email: "p@grp.com"}].to_json)
  calendar.set_groups("casc.high2@example.com", [{id: "group-priority", email: "p@grp.com"}].to_json)

  cstart = now + 3600_i64 * 120
  cend = cstart + 3600_i64
  # two low-priority occupants (one per space) and two higher-priority bookings,
  # all overlapping — each preemptor could take either space
  staff.set_bookings([
    build_booking.call(78001_i64, "casc.low1@example.com",
      cstart, cend, "asset-ca", true, ext_car),
    build_booking.call(78002_i64, "casc.low2@example.com",
      cstart, cend, "asset-cb", true, ext_car),
    build_booking.call(78003_i64, "casc.high1@example.com",
      cstart, cend, "unallocated-78003", false, ext_car),
    build_booking.call(78004_i64, "casc.high2@example.com",
      cstart, cend, "unallocated-78004", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # nobody actually displaced (disabled)
  staff.last_update_for(78001_i64).should be_nil
  staff.last_update_for(78002_i64).should be_nil

  # the report cascades across BOTH spaces/occupants rather than repeating one
  report3 = status[:displacement_report].as_a
  report3.size.should eq(2)
  report3.map { |e| e["space"].as_s }.should eq(["CA", "CB"])
  report3.map { |e| e["displaced"].as_s }.should eq(["casc.low1@example.com", "casc.low2@example.com"])
  report3.map { |e| e["replaced_with"].as_s }.should eq(["casc.high1@example.com", "casc.high2@example.com"])

  # ===========================================================
  # Test 79: manual_displacement swaps a space from one user to another, creating
  # a wait-list booking for the assignee when they don't have one. Both sides are
  # notified.
  # ===========================================================

  settings({
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    # manual displacement bypasses the policy, even when off
    allow_displacement: false,
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json) # asset-r1 / identifier R1
  gallagher.set_cardholder("evicted@example.com", "ch-evicted")
  gallagher.set_cardholder("vip@example.com", "ch-vip")
  calendar.set_groups("evicted@example.com", default_grp.to_json)
  calendar.set_groups("vip@example.com", default_grp.to_json)
  # the assignee (vip) is resolvable in the directory (for the created booking)
  calendar.set_user("vip@example.com", {email: "vip@example.com", name: "VIP User"}.to_json)

  mstart = now + 3600_i64 * 200
  mend = mstart + 3600_i64
  # only the displaced user has a booking; the assignee has none (it's created)
  staff.set_bookings([
    build_booking.call(80001_i64, "evicted@example.com",
      mstart, mend, "asset-r1", true, ext_car),
  ].to_json)

  exec(:manual_displacement, mstart, {"evicted@example.com" => "vip@example.com"}).get
  sleep 100.milliseconds

  # the displaced user was moved off the space and notified with a reason
  staff.last_update_for(80001_i64).should eq("unallocated-displaced-80001")
  staff.last_state(80001_i64).should eq("wait_list")
  mailer.sent?("evicted@example.com", "parking_request", "displaced").should eq(true)
  mailer.arg_for("evicted@example.com", "parking_request", "displaced", "reason")
    .should eq("Your parking space has been reassigned.")

  # a wait-list booking was created for the assignee and assigned the space
  vip_id = staff.created_id_for("vip@example.com")
  vip_id.should_not be_nil
  vip_id = vip_id.not_nil!
  staff.last_update_for(vip_id).should eq("asset-r1")
  staff.approved.includes?(vip_id).should eq(true)
  staff.last_state(vip_id).should eq("access_granted_emailed")
  mailer.sent?("vip@example.com", "parking_request", "approved_gallagher-group1").should eq(true)
  # the created booking carries the assignee's directory name (via calendar.get_user)
  mailer.arg_for("vip@example.com", "parking_request", "approved_gallagher-group1", "visitor_name")
    .should eq("VIP User")

  # ===========================================================
  # Test 80: when the assignee already has a (wait-list) booking, manual
  # displacement assigns THAT booking rather than creating a new one.
  # ===========================================================

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([two_regular[0]].to_json)
  gallagher.set_cardholder("evicted2@example.com", "ch-evicted2")
  gallagher.set_cardholder("vip2@example.com", "ch-vip2")
  calendar.set_groups("evicted2@example.com", default_grp.to_json)
  calendar.set_groups("vip2@example.com", default_grp.to_json)

  staff.set_bookings([
    build_booking.call(81001_i64, "evicted2@example.com",
      mstart, mend, "asset-r1", true, ext_car),
    # the assignee already has a wait-list booking for the same time
    build_booking.call(81002_i64, "vip2@example.com",
      mstart, mend, "unallocated-81002", false, ext_car),
  ].to_json)

  exec(:manual_displacement, mstart, {"evicted2@example.com" => "vip2@example.com"}).get
  sleep 100.milliseconds

  # no new booking was created — the existing one was assigned the space
  staff.created_id_for("vip2@example.com").should be_nil
  staff.last_update_for(81001_i64).should eq("unallocated-displaced-81001")
  staff.last_update_for(81002_i64).should eq("asset-r1")
  staff.approved.includes?(81002_i64).should eq(true)
  mailer.sent?("vip2@example.com", "parking_request", "approved_gallagher-group1").should eq(true)
  mailer.sent?("evicted2@example.com", "parking_request", "displaced").should eq(true)

  # ===========================================================
  # Test 81: a wait-listed booking that started in the past AND was created more
  # than 3 hours ago is stale — it is NOT allocated (avoids clashing with
  # bookings that have since ended). Past-start-but-recently-created and
  # future-start-but-old bookings are still allocated.
  # ===========================================================

  settings({
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  stale_spaces = [
    {id: "asset-st1", identifier: "ST1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
     features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
    {id: "asset-st2", identifier: "ST2", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
     features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
    {id: "asset-st3", identifier: "ST3", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
     features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
  ]
  staff.set_assets(stale_spaces.to_json)
  gallagher.set_cardholder("stale.user@example.com", "ch-stale")
  gallagher.set_cardholder("walkin.user@example.com", "ch-walkin")
  gallagher.set_cardholder("future.user@example.com", "ch-future")
  calendar.set_groups("stale.user@example.com", default_grp.to_json)
  calendar.set_groups("walkin.user@example.com", default_grp.to_json)
  calendar.set_groups("future.user@example.com", default_grp.to_json)

  stale_booking = ->(id : Int64, user : String, b_start : Int64, b_end : Int64, created_at : Int64) do
    {
      id:              id,
      booking_type:    "parking",
      booking_start:   b_start,
      booking_end:     b_end,
      asset_id:        "unallocated-#{id}",
      asset_ids:       ["unallocated-#{id}"],
      user_id:         "user-#{id}",
      user_email:      user,
      user_name:       user,
      booked_by_email: user,
      booked_by_name:  user,
      zones:           ["zone-building"],
      created:         created_at,
      approved:        false,
      rejected:        false,
      deleted:         false,
      extension_data:  ext_car,
    }
  end

  staff.set_bookings([
    # started 1h ago, created 4h ago -> STALE -> not allocated
    stale_booking.call(83001_i64, "stale.user@example.com", now - 3600_i64, now + 3600_i64, now - 4_i64 * 3600),
    # started 1h ago, created just now -> walk-in, allocated
    stale_booking.call(83002_i64, "walkin.user@example.com", now - 3600_i64, now + 3600_i64, now),
    # starts in 2h, created 4h ago -> future start, allocated
    stale_booking.call(83003_i64, "future.user@example.com", now + 3600_i64 * 2, now + 3600_i64 * 3, now - 4_i64 * 3600),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the stale booking is left alone (no allocation attempt)
  staff.last_update_for(83001_i64).should be_nil
  staff.approved.includes?(83001_i64).should eq(false)
  # the recently-created (walk-in) and future bookings are still allocated
  staff.last_update_for(83002_i64).should_not be_nil
  staff.last_update_for(83003_i64).should_not be_nil

  # ===========================================================
  # Test 82: when calendar_invite_from is set, the approval email carries a
  # METHOD:REQUEST .ics invite for the allocated space, and a later displacement
  # emails a METHOD:CANCEL for the SAME booking UID — so the space is removed
  # from (not duplicated on) the user's calendar.
  # ===========================================================

  settings({
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    calendar_invite_from:      "parking@place.technology",
    calendar_invite_from_name: "Building Parking",
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  gallagher.set_cardholder("inv.user@example.com", "ch-inv")
  calendar.set_groups("inv.user@example.com", default_grp.to_json)

  inv_space = {
    id: "asset-inv1", identifier: "INV1", assigned_to: "",
    zones: ["zone-building", "zone-level-B1"],
    features: ["carpriority", "Open Basement"], notes: "Car",
    security_system_groups: [] of String, bookable: true,
  }
  staff.set_assets([inv_space].to_json)

  inv_start = now + 3600_i64 * 300
  inv_end = inv_start + 3600_i64
  staff.set_bookings([
    build_booking.call(84001_i64, "inv.user@example.com",
      inv_start, inv_end, "unallocated-84001", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # allocated + approval email sent for the Open Basement group
  staff.last_update_for(84001_i64).should eq("asset-inv1")
  mailer.sent?("inv.user@example.com", "parking_request", "approved_gallagher-group1").should eq(true)

  # the approval email carries a METHOD:REQUEST invite describing the space
  invite = mailer.attachment_for("inv.user@example.com", "parking_request", "approved_gallagher-group1")
  invite.should_not be_nil
  invite = invite.not_nil!
  invite.should contain("BEGIN:VCALENDAR")
  invite.should contain("METHOD:REQUEST")
  invite.should contain("UID:parking-84001@place.technology")
  invite.should contain("SEQUENCE:0")
  invite.should contain("DTSTART:#{Time.unix(inv_start).to_s("%Y%m%dT%H%M%SZ")}")
  invite.should contain("DTEND:#{Time.unix(inv_end).to_s("%Y%m%dT%H%M%SZ")}")
  invite.should contain("SUMMARY:Parking - INV1")
  invite.should contain("STATUS:CONFIRMED")
  invite.should contain("ORGANIZER;CN=Building Parking:mailto:parking@place.technology")
  invite.should contain("ATTENDEE;CN=inv.user@example.com;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:inv.user@example.com")

  # --- displacement: the space goes out of service, forcing a move off it ---
  staff.reset_calls
  mailer.reset
  # same space, now not bookable (e.g. flooded)
  staff.set_assets([inv_space.merge({bookable: false})].to_json)

  inv2_start = now + 3600_i64 * 320
  inv2_end = inv2_start + 3600_i64
  # the booking is already allocated on the space, with a location + last_changed
  staff.set_bookings([
    {
      id:              84001_i64,
      booking_type:    "parking",
      booking_start:   inv2_start,
      booking_end:     inv2_end,
      asset_id:        "asset-inv1",
      asset_ids:       ["asset-inv1"],
      user_id:         "user-84001",
      user_email:      "inv.user@example.com",
      user_name:       "inv.user@example.com",
      booked_by_email: "inv.user@example.com",
      booked_by_name:  "inv.user@example.com",
      zones:           ["zone-building"],
      created:         now - 500_i64,
      last_changed:    now,
      approved:        true,
      rejected:        false,
      deleted:         false,
      process_state:   "access_granted_emailed",
      extension_data:  {
        "vehicle_type" => JSON::Any.new("car"),
        "request_type" => JSON::Any.new("standard"),
        "location"     => JSON::Any.new("INV1"),
      },
    },
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the booking was moved off the out-of-service space and a displaced email sent
  staff.last_update_for(84001_i64).should eq("unallocated-displaced-84001")
  mailer.sent?("inv.user@example.com", "parking_request", "displaced").should eq(true)

  # that email carries a METHOD:CANCEL invite for the SAME UID, with a higher
  # SEQUENCE so clients supersede the earlier REQUEST and remove the entry
  cancel = mailer.attachment_for("inv.user@example.com", "parking_request", "displaced")
  cancel.should_not be_nil
  cancel = cancel.not_nil!
  cancel.should contain("METHOD:CANCEL")
  cancel.should contain("UID:parking-84001@place.technology")
  cancel.should contain("STATUS:CANCELLED")
  cancel.should contain("SEQUENCE:#{now + 1}")
  cancel.should contain("SUMMARY:Parking - INV1")

  # ===========================================================
  # Test 83: when a user cancels a booking that held a space, a cancellation
  # email + METHOD:CANCEL invite is sent (driven by the monitor event, since a
  # cancelled booking drops out of the allocation sweep). A cancelled booking
  # that was only ever wait-listed sends nothing.
  # ===========================================================

  settings({
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    calendar_invite_from:      "parking@place.technology",
    calendar_invite_from_name: "Building Parking",
  })
  sleep 100.milliseconds

  # clear the world so the sweep that a cancellation event also triggers is a
  # no-op and can't pollute the mailer assertions below
  staff.reset_calls
  mailer.reset
  staff.set_assets("[]")
  staff.set_bookings("[]")

  cancel_start = now + 3600_i64 * 340
  cancel_end = cancel_start + 3600_i64

  cancelled_booking = ->(state : String, asset : String) do
    {
      action:          "cancelled",
      id:              85001_i64,
      booking_type:    "parking",
      booking_start:   cancel_start,
      booking_end:     cancel_end,
      asset_id:        asset,
      asset_ids:       [asset],
      user_id:         "user-85001",
      user_email:      "cancel.user@example.com",
      user_name:       "Cancel User",
      booked_by_email: "cancel.user@example.com",
      booked_by_name:  "Cancel User",
      zones:           ["zone-building"],
      created:         now - 500_i64,
      last_changed:    now,
      approved:        true,
      rejected:        false,
      deleted:         false,
      process_state:   state,
      extension_data:  {"location" => "INV1"},
    }
  end

  # a cancelled booking that HELD a space -> notify + CANCEL invite
  publish("staff/booking/changed", cancelled_booking.call("access_granted_emailed", "asset-inv1").to_json)
  sleep 100.milliseconds

  mailer.sent?("cancel.user@example.com", "parking_request", "cancelled").should eq(true)
  ccancel = mailer.attachment_for("cancel.user@example.com", "parking_request", "cancelled")
  ccancel.should_not be_nil
  ccancel = ccancel.not_nil!
  ccancel.should contain("METHOD:CANCEL")
  ccancel.should contain("UID:parking-85001@place.technology")
  ccancel.should contain("STATUS:CANCELLED")
  ccancel.should contain("SEQUENCE:#{now + 1}")
  # the email names the space that was cancelled
  mailer.arg_for("cancel.user@example.com", "parking_request", "cancelled", "space_identifier").should eq("INV1")
  # marked handled so a repeated event won't re-notify
  staff.last_state(85001_i64).should eq("cancelled_emailed")

  # a repeat event for an already-notified cancellation does not re-send
  publish("staff/booking/changed", cancelled_booking.call("cancelled_emailed", "asset-inv1").to_json)
  sleep 100.milliseconds
  mailer.times_sent("cancel.user@example.com", "parking_request", "cancelled").should eq(1)

  # a cancelled booking that was only ever wait-listed -> nothing is sent
  mailer.reset
  publish("staff/booking/changed", {
    action:          "cancelled",
    id:              85002_i64,
    booking_type:    "parking",
    booking_start:   cancel_start,
    booking_end:     cancel_end,
    asset_id:        "unallocated-85002",
    asset_ids:       ["unallocated-85002"],
    user_id:         "user-85002",
    user_email:      "waitlist.user@example.com",
    user_name:       "Wait List User",
    booked_by_email: "waitlist.user@example.com",
    booked_by_name:  "Wait List User",
    zones:           ["zone-building"],
    created:         now - 500_i64,
    last_changed:    now,
    approved:        false,
    rejected:        false,
    deleted:         false,
    process_state:   "wait_list",
    extension_data:  {} of String => String,
  }.to_json)
  sleep 100.milliseconds
  mailer.send_count.should eq(0)

  # ===========================================================
  # Test 84: a PERSISTENT directory failure (all retries exhausted) must not
  # poison the priority cache. Sweep 1: every group lookup for a top-priority
  # user fails, so they resolve to nil -> treated as priority 0 for that run and
  # a default user (created earlier) takes the only space. Sweep 2: the directory
  # has recovered — the lookup must be RETRIED (nil is never cached) so the
  # user's true group priority is seen and they preempt the lower-priority
  # occupant.
  # ===========================================================

  retry_settings = {
    poll_rate:                       999_999,
    auto_approval_groups:            ["group-priority", "group-default"],
    displacement_notification_hours: 0,
    car_zone_priority:               ["carpriority", "shared"],
    bike_zone_priority:              ["bikepriority", "shared"],
    parking_areas:                   {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
    # retry twice, with no backoff, so the test doesn't actually sleep
    group_lookup_retries: 2,
    group_lookup_backoff: 0,
  }
  settings(retry_settings)
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  pr_space = [
    {id: "asset-pr1", identifier: "PR1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
     features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
  ].to_json
  staff.set_assets(pr_space)
  gallagher.set_cardholder("pexec.user@example.com", "ch-pexec")
  gallagher.set_cardholder("plowly.user@example.com", "ch-plowly")
  # pexec.user is in the TOP priority group; plowly.user is in no groups
  calendar.set_groups("pexec.user@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("plowly.user@example.com", [] of NamedTuple(id: String, email: String))
  # the directory is down for pexec.user for far more than the retry budget
  calendar.set_fail_groups("pexec.user@example.com", 100)

  pr_start = now + 3600_i64 * 360
  pr_end = pr_start + 3600_i64
  # plowly's booking was created EARLIER (lower id => earlier created), so it
  # wins the created_at tiebreak while pexec is wrongly at priority 0
  staff.set_bookings([
    build_booking.call(86001_i64, "plowly.user@example.com",
      pr_start, pr_end, "unallocated-86001", false, ext_car),
    build_booking.call(86002_i64, "pexec.user@example.com",
      pr_start, pr_end, "unallocated-86002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the lookup was attempted retries+1 times (initial + 2 retries) then gave up
  calendar.group_lookup_count("pexec.user@example.com").should eq(3)
  # during the outage the space went to the default user
  staff.last_update_for(86001_i64).should eq("asset-pr1")
  staff.last_update_for(86002_i64).should be_nil

  # --- the directory recovers ---
  calendar.set_fail_groups("pexec.user@example.com", 0)

  staff.reset_calls
  mailer.reset
  # world state after sweep 1: plowly holds the space, pexec is wait-listed
  plowly_allocated = build_booking.call(86001_i64, "plowly.user@example.com",
    pr_start, pr_end, "asset-pr1", true, ext_car)
  staff.set_bookings([
    plowly_allocated.merge({process_state: "access_granted_emailed"}),
    build_booking.call(86002_i64, "pexec.user@example.com",
      pr_start, pr_end, "unallocated-86002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the failed lookup must have been retried, not served from a cached 0
  calendar.group_lookup_count("pexec.user@example.com").should eq(4)
  # with their true priority visible, pexec preempts the priority-0 occupant
  staff.last_update_for(86002_i64).should eq("asset-pr1")
  staff.last_update_for(86001_i64).should eq("unallocated-displaced-86001")
  mailer.sent?("pexec.user@example.com", "parking_request", "approved_gallagher-group1").should eq(true)
  mailer.sent?("plowly.user@example.com", "parking_request", "displaced").should eq(true)

  # ===========================================================
  # Test 85: a TRANSIENT directory blip recovers WITHIN the sweep — the lookup
  # is retried and succeeds, so the top-group user keeps their true priority and
  # wins the space over an earlier-created default user in the SAME run (no
  # displacement round-trip needed).
  # ===========================================================

  settings(retry_settings)
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets(pr_space)
  gallagher.set_cardholder("texec.user@example.com", "ch-texec")
  gallagher.set_cardholder("tlowly.user@example.com", "ch-tlowly")
  calendar.set_groups("texec.user@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("tlowly.user@example.com", [] of NamedTuple(id: String, email: String))
  # the directory fails once for texec.user, then recovers (within the retries)
  calendar.set_fail_groups("texec.user@example.com", 1)

  tr_start = now + 3600_i64 * 380
  tr_end = tr_start + 3600_i64
  staff.set_bookings([
    build_booking.call(87001_i64, "tlowly.user@example.com",
      tr_start, tr_end, "unallocated-87001", false, ext_car),
    build_booking.call(87002_i64, "texec.user@example.com",
      tr_start, tr_end, "unallocated-87002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # one failure + one successful retry
  calendar.group_lookup_count("texec.user@example.com").should eq(2)
  # priority stayed accurate, so the top-group user won the only space outright
  staff.last_update_for(87002_i64).should eq("asset-pr1")
  staff.last_update_for(87001_i64).should be_nil
  mailer.sent?("texec.user@example.com", "parking_request", "approved_gallagher-group1").should eq(true)

  # ===========================================================
  # Test 86: a user with a permanent parking assignment already has standing
  # access to their space, so any booking they make is ignored by the allocator
  # — not allocated a (second) bookable space, not approved, not emailed — while
  # their permanent gallagher access is still granted. Other users allocate as
  # normal.
  # ===========================================================

  settings({
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  })
  sleep 100.milliseconds

  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([
    # a free bookable space...
    {id: "asset-book1", identifier: "BOOK1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
     features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
    # ...and a space permanently assigned to perm.user
    {id: "asset-perm1", identifier: "PERM1", assigned_to: "perm.user@example.com", zones: ["zone-building", "zone-level-B3"],
     features: ["Secure Basement"], notes: "Car", security_system_groups: [] of String, bookable: true},
  ].to_json)
  gallagher.set_cardholder("perm.user@example.com", "ch-perm")
  gallagher.set_cardholder("regular.user@example.com", "ch-regular")
  calendar.set_groups("perm.user@example.com", default_grp.to_json)
  calendar.set_groups("regular.user@example.com", default_grp.to_json)

  perm_start = now + 3600_i64 * 400
  perm_end = perm_start + 3600_i64
  staff.set_bookings([
    # the permanently-assigned user also makes a booking — must be ignored
    build_booking.call(88001_i64, "perm.user@example.com",
      perm_start, perm_end, "unallocated-88001", false, ext_car),
    # a regular user who should allocate as normal
    build_booking.call(88002_i64, "regular.user@example.com",
      perm_start, perm_end, "unallocated-88002", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the permanent user's booking is completely ignored
  staff.last_update_for(88001_i64).should be_nil
  staff.approved.includes?(88001_i64).should eq(false)
  mailer.any_sent_to?("perm.user@example.com").should eq(false)
  # ...but their permanent gallagher access is still in place, and they were NOT
  # granted the bookable space's group
  perm_access = gallagher.access_for("ch-perm")
  perm_access.should contain("gallagher-group3")
  perm_access.should_not contain("gallagher-group1")

  # the regular user allocates to the free bookable space as normal
  staff.last_update_for(88002_i64).should eq("asset-book1")
  mailer.sent?("regular.user@example.com", "parking_request", "approved_gallagher-group1").should eq(true)

  # ===========================================================
  # Electric Vehicle restriction (id 2). EV bookings only fit EV spaces (no
  # regular-space fallback) and are rejected — not wait-listed — when none is
  # free. EV spaces are the lowest-priority spaces for non-EV bookings, but may
  # still be used by them.
  # ===========================================================

  ev_settings = {
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  }

  # a regular bookable space + an EV space (both map to gallagher-group1 via
  # "Open Basement"; the EV space additionally carries the "Electric Vehicle"
  # feature). The EV space deliberately has the HIGHER zone preference
  # ("carpriority" vs the regular space's "shared") so that only the EV-last rule
  # can push it behind the regular space for non-EV bookings (Test 88).
  ev_reg_space = {id: "asset-reg1", identifier: "REG1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
                  features: ["shared", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true}
  ev_ev_space = {id: "asset-ev1", identifier: "EV1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
                 features: ["Electric Vehicle", "carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true}

  ev_ext = {"vehicle_type" => JSON::Any.new("car"), "space_restrictions" => JSON::Any.new(2_i64)}

  # -----------------------------------------------------------
  # Test 87: an EV booking is allocated to the EV space even when a regular space
  # is also free — it never takes a non-EV space.
  # -----------------------------------------------------------

  settings(ev_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([ev_reg_space, ev_ev_space].to_json)
  gallagher.set_cardholder("ev.driver@example.com", "ch-evdriver")
  calendar.set_groups("ev.driver@example.com", default_grp.to_json)

  ev_start = now + 3600_i64 * 420
  ev_end = ev_start + 3600_i64
  staff.set_bookings([
    build_booking.call(90001_i64, "ev.driver@example.com",
      ev_start, ev_end, "unallocated-90001", false, ev_ext),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  staff.last_update_for(90001_i64).should eq("asset-ev1")
  mailer.sent?("ev.driver@example.com", "parking_request", "approved_gallagher-group1").should eq(true)

  # -----------------------------------------------------------
  # Test 88: EV spaces are the last resort for non-EV bookings. Two overlapping
  # regular bookings, higher priority first: the higher-priority one takes the
  # regular space, the lower-priority one falls back to the EV space (proving a
  # non-EV booking CAN use an EV space, but only after regular spaces run out).
  # -----------------------------------------------------------

  settings(ev_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([ev_reg_space, ev_ev_space].to_json)
  gallagher.set_cardholder("hi.user@example.com", "ch-hi")
  gallagher.set_cardholder("lo.user@example.com", "ch-lo")
  # hi.user is in the top group; lo.user is in no group
  calendar.set_groups("hi.user@example.com", [{id: "group-priority", email: "priority@grp.com"}].to_json)
  calendar.set_groups("lo.user@example.com", [] of NamedTuple(id: String, email: String))

  lr_start = now + 3600_i64 * 440
  lr_end = lr_start + 3600_i64
  staff.set_bookings([
    build_booking.call(90101_i64, "hi.user@example.com",
      lr_start, lr_end, "unallocated-90101", false, ext_car),
    build_booking.call(90102_i64, "lo.user@example.com",
      lr_start, lr_end, "unallocated-90102", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # higher priority gets the regular space; lower priority gets the EV space last
  staff.last_update_for(90101_i64).should eq("asset-reg1")
  staff.last_update_for(90102_i64).should eq("asset-ev1")

  # -----------------------------------------------------------
  # Test 89: an EV booking with NO EV space available is WAIT-LISTED — it is NOT
  # allocated a regular space (no fallback) and NOT rejected.
  # -----------------------------------------------------------

  settings(ev_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  # only a regular space exists — no EV space at all
  staff.set_assets([ev_reg_space].to_json)
  gallagher.set_cardholder("ev.noev@example.com", "ch-evnoev")
  calendar.set_groups("ev.noev@example.com", default_grp.to_json)

  nr_start = now + 3600_i64 * 460
  nr_end = nr_start + 3600_i64
  staff.set_bookings([
    build_booking.call(90201_i64, "ev.noev@example.com",
      nr_start, nr_end, "unallocated-90201", false, ev_ext),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # wait-listed: never allocated the (non-EV) regular space, not approved
  staff.last_update_for(90201_i64).should be_nil
  staff.approved.includes?(90201_i64).should eq(false)
  staff.last_state(90201_i64).should eq("wait_list")
  mailer.sent?("ev.noev@example.com", "parking_request", "wait_list").should eq(true)

  # -----------------------------------------------------------
  # Test 90: an EV booking is WAIT-LISTED when the only EV space is already held
  # by an equal-priority booking (nothing to preempt).
  # -----------------------------------------------------------

  settings(ev_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([ev_ev_space].to_json)
  gallagher.set_cardholder("ev.first@example.com", "ch-evfirst")
  gallagher.set_cardholder("ev.second@example.com", "ch-evsecond")
  # both in no group => equal (priority 0), so the second can't preempt the first
  calendar.set_groups("ev.first@example.com", [] of NamedTuple(id: String, email: String))
  calendar.set_groups("ev.second@example.com", [] of NamedTuple(id: String, email: String))

  bz_start = now + 3600_i64 * 480
  bz_end = bz_start + 3600_i64
  staff.set_bookings([
    # 90301 is created earlier (lower id) so it wins the only EV space
    build_booking.call(90301_i64, "ev.first@example.com",
      bz_start, bz_end, "unallocated-90301", false, ev_ext),
    build_booking.call(90302_i64, "ev.second@example.com",
      bz_start, bz_end, "unallocated-90302", false, ev_ext),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # first takes the EV space; second is wait-listed (no EV space free, can't preempt)
  staff.last_update_for(90301_i64).should eq("asset-ev1")
  staff.last_update_for(90302_i64).should be_nil
  staff.last_state(90302_i64).should eq("wait_list")
  mailer.sent?("ev.second@example.com", "parking_request", "wait_list").should eq(true)

  # ===========================================================
  # Test 91: an unallocated booking with NO vehicle_type in extension_data is
  # rejected (not allocated, not wait-listed) and a rejection email is sent. A
  # booking that DOES carry a vehicle_type allocates as normal in the same run.
  # ===========================================================

  vt_settings = {
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Electric Vehicle"},
    ],
  }

  vt_reg_space = {id: "asset-vt1", identifier: "VT1", assigned_to: "", zones: ["zone-building", "zone-level-B1"],
                  features: ["carpriority", "Open Basement"], notes: "Car", security_system_groups: [] of String, bookable: true}
  # a booking whose extension_data has no vehicle_type key at all
  no_vehicle_ext = {"request_type" => JSON::Any.new("standard")}

  settings(vt_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([vt_reg_space].to_json)
  gallagher.set_cardholder("novt.user@example.com", "ch-novt")
  gallagher.set_cardholder("hasvt.user@example.com", "ch-hasvt")
  calendar.set_groups("novt.user@example.com", default_grp.to_json)
  calendar.set_groups("hasvt.user@example.com", default_grp.to_json)

  vt_start = now + 3600_i64 * 500
  vt_end = vt_start + 3600_i64
  staff.set_bookings([
    build_booking.call(90401_i64, "novt.user@example.com",
      vt_start, vt_end, "unallocated-90401", false, no_vehicle_ext),
    build_booking.call(90402_i64, "hasvt.user@example.com",
      vt_start, vt_end, "unallocated-90402", false, ext_car),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # the no-vehicle-type booking is rejected: not allocated, not wait-listed
  staff.rejected?(90401_i64).should eq(true)
  staff.last_update_for(90401_i64).should be_nil
  staff.last_state(90401_i64).should eq("rejected")
  mailer.sent?("novt.user@example.com", "parking_request", "rejected").should eq(true)
  mailer.sent?("novt.user@example.com", "parking_request", "wait_list").should eq(false)

  # the booking WITH a vehicle_type still allocates normally
  staff.last_update_for(90402_i64).should eq("asset-vt1")
  staff.rejected?(90402_i64).should eq(false)
  mailer.sent?("hasvt.user@example.com", "parking_request", "approved_gallagher-group1").should eq(true)

  # ===========================================================
  # Test 92: an ALREADY-ALLOCATED booking with no vehicle_type is NOT rejected —
  # the rejection only applies to bookings not yet allocated.
  # ===========================================================

  settings(vt_settings)
  sleep 100.milliseconds
  staff.reset_calls
  mailer.reset
  gallagher.reset
  staff.set_assets([vt_reg_space].to_json)
  gallagher.set_cardholder("alloc.novt@example.com", "ch-allocnovt")
  calendar.set_groups("alloc.novt@example.com", default_grp.to_json)

  av_start = now + 3600_i64 * 520
  av_end = av_start + 3600_i64
  # already on the space (asset-vt1), no vehicle_type
  staff.set_bookings([
    build_booking.call(90501_i64, "alloc.novt@example.com",
      av_start, av_end, "asset-vt1", false, no_vehicle_ext),
  ].to_json)
  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  # kept its allocation, approved, NOT rejected
  staff.rejected?(90501_i64).should eq(false)
  staff.approved.includes?(90501_i64).should eq(true)
  mailer.sent?("alloc.novt@example.com", "parking_request", "rejected").should eq(false)
  mailer.sent?("alloc.novt@example.com", "parking_request", "approved_gallagher-group1").should eq(true)
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @assets_json : String = "[]"
  @bookings_json : String = "[]"
  @updates : Hash(Int64, String) = {} of Int64 => String
  @approved_set : Array(Int64) = [] of Int64
  # process_state keyed by "id:instance" so per-recurring-instance state is
  # tracked independently, matching the backend (booking_instances carry their
  # own process_state column). The state IS reflected on the next query_bookings
  # re-fetch, so the driver's duplicate-email guards work as in production.
  @states : Hash(String, String) = {} of String => String
  # records the period_end passed to the most recent query_bookings call so
  # tests can assert the allocation window
  getter last_query_period_end : Int64? = nil

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
    @rejected_set = [] of Int64
    @states = {} of String => String
    @fail_updates = [] of Int64
    @update_instances = {} of Int64 => String
    @approve_instances = {} of Int64 => String
    @updates_by_instance = {} of String => String
    @approved_instances = [] of String
    @clash_updates = Set(String).new
    @update_calls = {} of Int64 => Int32
    @fail_query = false
    @created_bookings = [] of JSON::Any
    @created_ids = {} of String => Int64
  end

  # when true, query_bookings raises (simulating the staff API erroring)
  @fail_query : Bool = false

  def set_fail_query(value : Bool)
    @fail_query = value
  end

  # (booking_id, asset_id) pairs the staff API should reject as a clashing
  # booking (HTTP 409) — simulating a space booked outside the driver's view
  @clash_updates : Set(String) = Set(String).new
  # count of (successful) update_booking calls per booking id
  @update_calls : Hash(Int64, Int32) = {} of Int64 => Int32

  def clash_update_for(booking_id : Int64, asset_id : String)
    @clash_updates << "#{booking_id}:#{asset_id}"
  end

  def update_count_for(booking_id : Int64) : Int32
    @update_calls[booking_id]? || 0
  end

  # the `instance` param of the last update_booking / approve call per booking,
  # recorded as .inspect ("nil" when the call was parent-level)
  @update_instances : Hash(Int64, String) = {} of Int64 => String
  @approve_instances : Hash(Int64, String) = {} of Int64 => String
  # per-(booking, instance) records so recurring instances can be asserted
  # independently
  @updates_by_instance : Hash(String, String) = {} of String => String
  @approved_instances : Array(String) = [] of String

  def last_update_instance_for(booking_id : Int64) : String?
    @update_instances[booking_id]?
  end

  def last_approve_instance_for(booking_id : Int64) : String?
    @approve_instances[booking_id]?
  end

  # asset set by update_booking for a specific (booking, instance), nil if never called
  def update_for(booking_id : Int64, instance : Int64?) : String?
    @updates_by_instance["#{booking_id}:#{instance}"]?
  end

  def approved_instance?(booking_id : Int64, instance : Int64?) : Bool
    @approved_instances.includes?("#{booking_id}:#{instance}")
  end

  # booking ids whose update_booking calls should fail (simulating the staff
  # API rejecting the change, e.g. a clashing booking)
  @fail_updates : Array(Int64) = [] of Int64

  def fail_update_for(booking_id : Int64)
    @fail_updates << booking_id
  end

  def last_update_for(booking_id : Int64) : String?
    @updates[booking_id]?
  end

  def approved : Array(Int64)
    @approved_set
  end

  private def state_key(booking_id, instance) : String
    "#{booking_id}:#{instance}"
  end

  # convenience for the common nil-instance bookings used across most tests
  def last_state(booking_id : Int64) : String?
    @states[state_key(booking_id, nil)]?
  end

  def last_state(booking_id : Int64, instance : Int64?) : String?
    @states[state_key(booking_id, instance)]?
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
    raise "simulated query_bookings failure" if @fail_query
    @last_query_period_end = period_end

    # overlay any persisted per-instance process_state, mirroring how the
    # backend reflects booking_state writes on the next fetch
    source = (JSON.parse(@bookings_json).as_a + @created_bookings)
    source = source.select { |b| b["user_email"]?.try(&.as_s?) == email } if email
    bookings = source.map do |booking|
      id = booking["id"].as_i64
      inst = booking["instance"]?.try(&.as_i64?)
      if state = @states[state_key(id, inst)]?
        hash = booking.as_h.dup
        hash["process_state"] = JSON::Any.new(state)
        JSON::Any.new(hash)
      else
        booking
      end
    end
    JSON::Any.new(bookings)
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    bookings = JSON.parse(@bookings_json).as_a
    found = bookings.find { |b| b["id"].as_i64 == booking_id.to_s.to_i64 }
    found || JSON::Any.new({} of String => JSON::Any)
  end

  # bookings created via create_booking this test (mirrors them into queries)
  @created_bookings : Array(JSON::Any) = [] of JSON::Any
  @created_ids : Hash(String, Int64) = {} of String => Int64
  @next_created_id : Int64 = 90001_i64

  # the id assigned to the booking created for a given user email (nil if none)
  def created_id_for(email : String) : Int64?
    @created_ids[email.downcase]?
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
    approved : Bool? = nil,
    process_state : String? = nil,
    extension_data : JSON::Any? = nil,
    asset_ids : Array(String)? = nil,
  )
    id = @next_created_id
    @next_created_id += 1
    @created_ids[user_email.downcase] = id
    booking = {
      id:              id,
      booking_type:    booking_type,
      booking_start:   booking_start,
      booking_end:     booking_end,
      asset_id:        asset_id,
      asset_ids:       asset_ids || [asset_id],
      user_id:         user_id,
      user_email:      user_email,
      user_name:       user_name,
      booked_by_email: user_email,
      booked_by_name:  user_name,
      zones:           zones,
      created:         booking_start,
      approved:        approved,
      rejected:        false,
      deleted:         false,
      process_state:   process_state,
      extension_data:  extension_data,
    }
    @created_bookings << JSON.parse(booking.to_json)
    booking
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
    id = booking_id.to_s.to_i64
    raise "simulated update_booking failure for #{id}" if @fail_updates.includes?(id)
    if asset_id && @clash_updates.includes?("#{id}:#{asset_id}")
      raise "issue updating booking #{id}: 409 Conflicting booking"
    end
    if asset_id
      @updates[id] = asset_id
      @update_instances[id] = instance.inspect
      @updates_by_instance["#{id}:#{instance}"] = asset_id
      @update_calls[id] = (@update_calls[id]? || 0) + 1
    end
    true
  end

  def approve(booking_id : String | Int64, instance : Int64? = nil)
    id = booking_id.to_s.to_i64
    @approved_set << id
    @approve_instances[id] = instance.inspect
    @approved_instances << "#{id}:#{instance}"
    true
  end

  @rejected_set : Array(Int64) = [] of Int64

  def reject(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    @rejected_set << booking_id.to_s.to_i64
    true
  end

  def rejected : Array(Int64)
    @rejected_set
  end

  def rejected?(booking_id : Int64) : Bool
    @rejected_set.includes?(booking_id)
  end

  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    @states[state_key(booking_id.to_s.to_i64, instance)] = state
    true
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  @groups : Hash(String, String) = {} of String => String
  # email => full user JSON (with an unmapped object for directory id fields)
  @users : Hash(String, String) = {} of String => String
  @last_additional_fields : Array(String)? = nil
  # count of get_groups calls per (downcased) user, so tests can assert the
  # driver's priority cache avoids repeat lookups
  @group_lookup_calls : Hash(String, Int32) = {} of String => Int32

  def group_lookup_count(user : String) : Int32
    @group_lookup_calls[user.downcase]? || 0
  end

  def set_groups(user_email : String, groups_json : String)
    @groups[user_email.downcase] = groups_json
  end

  def set_groups(user_email : String, groups : Array(NamedTuple(id: String, email: String)))
    @groups[user_email.downcase] = groups.to_json
  end

  # remaining get_groups failures per user — each call decrements. Set a small
  # number for a transient outage that recovers, or a large one for a persistent
  # outage. 0 (or unset) always succeeds.
  @fail_groups : Hash(String, Int32) = {} of String => Int32

  def set_fail_groups(user_email : String, times : Int32)
    @fail_groups[user_email.downcase] = times
  end

  def get_groups(user_id : String)
    @group_lookup_calls[user_id.downcase] = (@group_lookup_calls[user_id.downcase]? || 0) + 1
    if (remaining = @fail_groups[user_id.downcase]?) && remaining > 0
      @fail_groups[user_id.downcase] = remaining - 1
      raise "simulated directory failure"
    end
    raw = @groups[user_id.downcase]?
    raw ? JSON.parse(raw) : JSON.parse("[]")
  end

  # register a user with an employee id surfaced via unmapped (mirrors MS Graph)
  def set_user_employee_id(user_email : String, employee_id : String, key : String = "employeeId")
    @users[user_email.downcase] = {
      email:    user_email,
      name:     user_email,
      unmapped: {key => employee_id},
    }.to_json
  end

  # variant where the directory surfaces the id as a JSON number
  def set_user_employee_id(user_email : String, employee_id : Int64, key : String = "employeeId")
    @users[user_email.downcase] = {
      email:    user_email,
      name:     user_email,
      unmapped: {key => employee_id},
    }.to_json
  end

  # register an arbitrary user JSON payload (e.g. one missing the employee id)
  def set_user(user_email : String, user_json : String)
    @users[user_email.downcase] = user_json
  end

  def last_additional_fields : Array(String)?
    @last_additional_fields
  end

  def get_user(user_id : String, additional_fields : Array(String)? = nil)
    @last_additional_fields = additional_fields
    if raw = @users[user_id.downcase]?
      JSON.parse(raw)
    else
      JSON.parse({email: user_id, name: user_id}.to_json)
    end
  end
end

# :nodoc:
class GallagherMock < DriverSpecs::MockDriver
  # value may be a String or Int64 cardholder id (the real interface returns
  # `String | Int64 | Nil`), so the integer path can be exercised
  @cardholders : Hash(String, String | Int64) = {} of String => String | Int64

  # a single time-bounded (or permanent) access grant, mirroring a Gallagher
  # cardholder access-group entry
  struct Membership
    include JSON::Serializable

    getter zone : String
    getter from : Int64?
    getter until_u : Int64?

    def initialize(@zone, @from, @until_u)
    end
  end

  # cardholder_id => grants
  @memberships : Hash(String, Array(Membership)) = Hash(String, Array(Membership)).new

  def set_cardholder(email : String, cardholder_id : String)
    @cardholders[email.downcase] = cardholder_id
  end

  def set_cardholder(email : String, cardholder_id : Int64)
    @cardholders[email.downcase] = cardholder_id
  end

  def reset
    @memberships = Hash(String, Array(Membership)).new
  end

  # count of card_holder_id_lookup calls per (downcased) email, so tests can
  # assert the driver's lookup cache avoids repeat queries
  @lookup_calls : Hash(String, Int32) = {} of String => Int32

  def lookup_count(email : String) : Int32
    @lookup_calls[email.downcase]? || 0
  end

  # zone ids the cardholder currently has any access to (de-duplicated)
  def access_for(cardholder_id : String) : Array(String)
    (@memberships[cardholder_id]? || [] of Membership).map(&.zone).uniq!
  end

  # raw membership-row count for a (cardholder, zone) — access_for de-duplicates
  # zones, so use this to detect a double-grant of the same group
  def membership_count(cardholder_id : String, zone : String) : Int32
    (@memberships[cardholder_id]? || [] of Membership).count { |m| m.zone == zone }
  end

  # all until-windows recorded for a cardholder in a given zone
  def untils_for(cardholder_id : String, zone : String) : Array(Int64?)
    (@memberships[cardholder_id]? || [] of Membership).select { |m| m.zone == zone }.map(&.until_u)
  end

  # the from-window recorded for a cardholder in a given zone/until (nil if none)
  def from_for(cardholder_id : String, zone : String, until_u : Int64?) : Int64?
    (@memberships[cardholder_id]? || [] of Membership).find { |m| m.zone == zone && m.until_u == until_u }.try(&.from)
  end

  def card_holder_id_lookup(email : String)
    @lookup_calls[email.downcase] = (@lookup_calls[email.downcase]? || 0) + 1
    @cardholders[email.downcase]?
  end

  # mirrors Gallagher's access_group_member? window matching.
  # NOTE: the driver always passes from=nil to member?/remove (it matches on
  # until only — see parking_approvals.cr), so the from+until branch below is
  # never exercised via the driver; it's kept for full API fidelity.
  private def window_match?(m : Membership, from_unix : Int64?, until_unix : Int64?) : Bool
    if from_unix || until_unix
      if from_unix && until_unix
        m.from == from_unix && m.until_u == until_unix
      elsif from_unix
        m.from == from_unix
      else
        m.until_u == until_unix
      end
    else
      # general access has no end window
      m.until_u.nil?
    end
  end

  def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    list = @memberships[card_holder_id.to_s]?
    return nil unless list
    match = list.find { |m| m.zone == zone_id.to_s && window_match?(m, from_unix, until_unix) }
    match ? "href-#{zone_id}-#{card_holder_id}-#{until_unix}" : nil
  end

  def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    list = @memberships[card_holder_id.to_s] ||= [] of Membership
    exists = list.any? { |m| m.zone == zone_id.to_s && m.from == from_unix && m.until_u == until_unix }
    list << Membership.new(zone_id.to_s, from_unix, until_unix) unless exists
    true
  end

  def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    list = @memberships[card_holder_id.to_s]?
    list.try(&.reject! { |m| m.zone == zone_id.to_s && window_match?(m, from_unix, until_unix) })
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

  @sent : Array(NamedTuple(to: String, template: Tuple(String, String), args: TemplateItems, attachments: Array(Attachment))) = [] of NamedTuple(to: String, template: Tuple(String, String), args: TemplateItems, attachments: Array(Attachment))
  # when true, every send_template raises (simulating a mailer/SMTP failure)
  @fail_send : Bool = false

  def set_fail_send(value : Bool)
    @fail_send = value
  end

  def reset
    @sent = [] of NamedTuple(to: String, template: Tuple(String, String), args: TemplateItems, attachments: Array(Attachment))
    self[:send_count] = 0
    self[:last_template] = nil
    self[:last_to] = nil
    @fail_send = false
  end

  def last_template
    self[:last_template]
  end

  def last_to
    self[:last_to]
  end

  def send_count : Int32
    self[:send_count]?.try(&.as_i) || 0
  end

  # was a specific (to, template) pair sent since the last reset?
  def sent?(to : String, ns : String, name : String) : Bool
    @sent.any? { |s| s[:to] == to && s[:template] == {ns, name} }
  end

  # was ANY email sent to this recipient since the last reset?
  def any_sent_to?(to : String) : Bool
    @sent.any? { |s| s[:to] == to }
  end

  # how many times a (to, template) pair was sent since the last reset
  def times_sent(to : String, ns : String, name : String) : Int32
    @sent.count { |s| s[:to] == to && s[:template] == {ns, name} }
  end

  # a template arg from the most recent (to, template) send (nil if none / unset)
  def arg_for(to : String, ns : String, name : String, key : String) : String?
    sent = @sent.reverse.find { |s| s[:to] == to && s[:template] == {ns, name} }
    sent.try { |s| s[:args][key]?.try(&.to_s) }
  end

  # the decoded (base64) content of the first attachment on the most recent
  # (to, template) send — the .ics body for a parking calendar invite, or nil
  def attachment_for(to : String, ns : String, name : String) : String?
    sent = @sent.reverse.find { |s| s[:to] == to && s[:template] == {ns, name} }
    sent.try { |s| s[:attachments].first?.try { |a| Base64.decode_string(a[:content]) } }
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
    raise "simulated mailer failure" if @fail_send
    recipient = to.is_a?(String) ? to : (to.first? || "")
    @sent << {to: recipient, template: template, args: args, attachments: attachments}
    self[:last_template] = template
    self[:last_to] = recipient
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
