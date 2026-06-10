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
      "Open Basement"   => "gallagher-group1",
      "Mezzanine"       => "gallagher-group2",
      "Secure Basement" => "gallagher-group3",
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
  staff.last_state(11001_i64, now + 3600 * 90).should eq("access_granted")

  # subsequent sweeps must NOT re-send — the per-instance process_state is
  # reflected on re-fetch and guards the email
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  exec(:process_parking_bookings).get
  sleep 100.milliseconds
  mailer.send_count.should eq(1)

  # ===========================================================
  # Test 12: the allocation window ends at the upcoming Friday 23:59 in the
  # configured timezone (control_system timezone is Australia/Sydney in specs).
  # ===========================================================

  staff.reset_calls
  mailer.reset
  staff.set_bookings("[]")

  exec(:process_parking_bookings).get
  sleep 100.milliseconds

  tz = Time::Location.load("Australia/Sydney")
  now_local = Time.local(tz)
  days_until_friday = (Time::DayOfWeek::Friday.value - now_local.day_of_week.value) % 7
  expected_end = (now_local + days_until_friday.days).at_end_of_day

  period_end = staff.last_query_period_end.not_nil!
  period_end.should eq(expected_end.to_unix)

  cutoff = Time.unix(period_end).in(tz)
  cutoff.day_of_week.should eq(Time::DayOfWeek::Friday)
  cutoff.hour.should eq(23)
  cutoff.minute.should eq(59)

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
  staff.last_state(80001_i64).should eq("access_granted")
  mailer.sent?("mid.user@example.com", "parking_request", "displaced").should eq(false)

  # ===========================================================
  # Time-bounded access. Reconfigure with a known access_minutes_before and a
  # single car space mapped to gallagher-group1 (email-lookup path).
  # ===========================================================

  win_settings = {
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

  # moved off the now-unmapped asset-temp (notified) and re-allocated to spare
  mailer.sent?("trans.user@example.com", "parking_request", "displaced").should eq(true)
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
    poll_rate:            999_999,
    auto_approval_groups: ["group-priority", "group-default"],
    car_zone_priority:    ["carpriority", "shared"],
    bike_zone_priority:   ["bikepriority", "shared"],
    parking_areas:        {
      "Open Basement"   => "gallagher-group1",
      "VIP Basement"    => "gallagher-group1", # same group as Open Basement
      "Secure Basement" => "gallagher-group3",
    },
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
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

  # the overlapping lower-priority occupant was moved off FIRST
  staff.last_update_for(44001_i64).should eq("unallocated-displaced-44001")
  mailer.sent?("normal.user@example.com", "parking_request", "displaced").should eq(true)
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
    @states = {} of String => String
    @fail_updates = [] of Int64
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
    @last_query_period_end = period_end

    # overlay any persisted per-instance process_state, mirroring how the
    # backend reflects booking_state writes on the next fetch
    bookings = JSON.parse(@bookings_json).as_a.map do |booking|
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
    if asset_id
      @updates[id] = asset_id
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

  def send_count : Int32
    self[:send_count]?.try(&.as_i) || 0
  end

  # was a specific (to, template) pair sent since the last reset?
  def sent?(to : String, ns : String, name : String) : Bool
    @sent.any? { |s| s[:to] == to && s[:template] == {ns, name} }
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
    recipient = to.is_a?(String) ? to : (to.first? || "")
    @sent << {to: recipient, template: template}
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
