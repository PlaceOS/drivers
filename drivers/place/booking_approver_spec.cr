require "placeos-driver/spec"

# publishes a booking created event, assigning the next booking id to `id_var`
macro create_booking(id_var, asset_ids, booking_type, approved)
  begin
    {{id_var}} += 1
    now = Time.utc.to_unix
    publish("staff/booking/changed", {
      action:          "create",
      id:              {{id_var}},
      booking_type:    {{booking_type}},
      booking_start:   now + 3600,
      booking_end:     now + 7200,
      asset_id:        {{asset_ids}}.first,
      asset_ids:       {{asset_ids}},
      user_id:         "user-1",
      user_email:      "user@org.com",
      user_name:       "User One",
      zones:           ["zone-building", "zone-level-1"],
      booked_by_name:  "User One",
      booked_by_email: "user@org.com",
      approved:        {{approved}},
      rejected:        false,
    }.to_json)
    sleep 200.milliseconds
    {{id_var}}.to_i64
  end
end

DriverSpecs.mock_driver "Place::BookingApprover" do
  system({
    StaffAPI: {StaffAPIMock},
  })

  settings({
    approve_booking_types: ["desk"],
    approve_zones:         ["zone-building"],
  })

  staff_api = system(:StaffAPI).as(StaffAPIMock)
  booking_id = 0

  # ==============
  # mode disabled
  # ==============
  id = create_booking(booking_id, ["desk-undefined"], "desk", false)
  staff_api.approved.should eq [id]
  staff_api.rejected.should be_empty
  exec(:status).get.not_nil!["bookable_assets"].should eq({} of String => Int32)

  # ==============
  # mode enabled
  # ==============
  staff_api.reset
  settings({
    approve_booking_types:   ["desk", "parking"],
    approve_zones:           ["zone-building"],
    reject_undefined_assets: true,
  })
  sleep 2.seconds

  # assets from every level of every building are cached, keyed by booking type
  exec(:status).get.not_nil!["bookable_assets"].should eq({"desk" => 3, "parking" => 1})
  staff_api.metadata_requests.sort.should eq [
    {"zone-building", "desks"},
    {"zone-building", "parking-spaces"},
    {"zone-building-2", "desks"},
    {"zone-building-2", "parking-spaces"},
  ]

  defined_desk = create_booking(booking_id, ["desk-1"], "desk", false)
  other_building_desk = create_booking(booking_id, ["desk-3"], "desk", false)
  undefined_desk = create_booking(booking_id, ["desk-undefined"], "desk", false)
  partially_defined = create_booking(booking_id, ["desk-1", "desk-undefined"], "desk", false)
  defined_parking = create_booking(booking_id, ["park-1"], "parking", false)
  desk_as_parking = create_booking(booking_id, ["desk-1"], "parking", false)
  already_approved = create_booking(booking_id, ["desk-undefined"], "desk", true)
  not_monitored = create_booking(booking_id, ["locker-undefined"], "locker", false)

  staff_api.approved.should eq [defined_desk, other_building_desk, defined_parking]
  staff_api.rejected.should eq [undefined_desk, partially_defined, desk_as_parking]
  staff_api.reject_sources.uniq.should eq ["booking_approval_driver"]
  staff_api.approved.should_not contain(already_approved)
  staff_api.rejected.should_not contain(not_monitored)

  exec(:status).get.not_nil!["bookings_rejected"].should eq 3

  # ===========================================
  # a failed refresh keeps the existing cache
  # ===========================================
  staff_api.reset
  staff_api.fail_metadata(true)
  expect_raises(Exception) { exec(:cache_bookable_assets).get }
  exec(:status).get.not_nil!["bookable_assets"].should eq({"desk" => 3, "parking" => 1})

  create_booking(booking_id, ["desk-2"], "desk", false)
  create_booking(booking_id, ["desk-undefined"], "desk", false)
  staff_api.approved.size.should eq 1
  staff_api.rejected.size.should eq 1

  # ==================================================================
  # bookings are never rejected when the cache has not loaded yet
  # ==================================================================
  staff_api.reset
  settings({
    approve_booking_types:   ["desk"],
    approve_zones:           ["zone-building"],
    reject_undefined_assets: false,
  })
  sleep 200.milliseconds
  staff_api.fail_metadata(true)
  settings({
    approve_booking_types:   ["desk"],
    approve_zones:           ["zone-building"],
    reject_undefined_assets: true,
  })
  sleep 2.seconds
  exec(:status).get.not_nil!["bookable_assets"].should eq({} of String => Int32)

  create_booking(booking_id, ["desk-undefined"], "desk", false)
  create_booking(booking_id, ["desk-1"], "desk", false)
  staff_api.approved.should be_empty
  staff_api.rejected.should be_empty

  # the next refresh succeeds and bookings are processed again
  staff_api.fail_metadata(false)
  exec(:cache_bookable_assets).get
  exec(:status).get.not_nil!["bookable_assets"].should eq({"desk" => 3})

  # ==========================================
  # empty metadata rejects all bookings of type
  # ==========================================
  staff_api.reset
  settings({
    approve_booking_types:   ["desk"],
    approve_zones:           ["zone-building"],
    reject_undefined_assets: true,
    asset_metadata_keys:     {"desk" => "missing-key"},
  })
  sleep 2.seconds
  exec(:status).get.not_nil!["bookable_assets"].should eq({"desk" => 0})
  id = create_booking(booking_id, ["desk-1"], "desk", false)
  staff_api.rejected.should eq [id]
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  LEVEL_METADATA = JSON.parse(%({
    "zone-building": [
      {
        "zone": {"id": "zone-level-1"},
        "metadata": {
          "desks": {
            "name": "desks",
            "details": [{"id": "desk-1", "name": "Desk 1"}, {"id": "desk-2", "name": "Desk 2"}]
          },
          "parking-spaces": {
            "name": "parking-spaces",
            "details": [{"id": "park-1", "name": "Park 1"}]
          }
        }
      },
      {"zone": {"id": "zone-level-2"}, "metadata": {}}
    ],
    "zone-building-2": [
      {
        "zone": {"id": "zone-level-3"},
        "metadata": {
          "desks": {
            "name": "desks",
            "details": [{"id": "desk-3", "name": "Desk 3"}, {"name": "Desk missing ID"}]
          }
        }
      }
    ]
  }))

  getter approved = [] of Int64
  getter rejected = [] of Int64
  getter reject_sources = [] of String?
  getter metadata_requests = [] of Tuple(String, String)
  @fail_metadata : Bool = false

  def fail_metadata(state : Bool)
    @fail_metadata = state
  end

  def reset
    @approved.clear
    @rejected.clear
    @reject_sources.clear
    @metadata_requests.clear
    @fail_metadata = false
  end

  def zones(tags : String)
    [{id: "zone-building"}, {id: "zone-building-2"}]
  end

  def metadata_children(id : String, key : String? = nil)
    raise "metadata unavailable" if @fail_metadata
    @metadata_requests << {id, key.to_s}
    LEVEL_METADATA[id].as_a.map do |level|
      metadata = level["metadata"].as_h.select { |name, _| name == key }
      {zone: level["zone"], metadata: metadata}
    end
  end

  def approve(booking_id : Int64, instance : Int64? = nil)
    @approved << booking_id
    true
  end

  def reject(booking_id : Int64, utm_source : String? = nil, instance : Int64? = nil)
    @rejected << booking_id
    @reject_sources << utm_source
    true
  end

  def query_bookings(
    type : String? = nil,
    zones : Array(String?) = [] of String?,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    period_end : Int64? = nil,
  )
    [] of Nil
  end
end
