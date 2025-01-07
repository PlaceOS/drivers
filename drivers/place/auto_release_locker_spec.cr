require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  system({
    StaffAPI: {StaffAPIMock},
  })
  resp = exec(:get_bookings).get
  resp.should_not be_nil
  resp.not_nil!.as_a.size.should eq 4
  resp = exec(:release_lockers).get
  resp.not_nil!.as_h["total"].should eq 4
  resp.not_nil!.as_h["released"].should eq 4
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  BOOKINGS = [
    {
      id:              1,
      user_id:         "user-one",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "locker_001",
      zones:           ["zone-1234"],
      booking_type:    "locker",
      booking_start:   (Time.utc - 10.hour).to_unix,
      booking_end:     (Time.utc + 5.hours).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore",
      description:     "",
      checked_in:      true,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-one",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              2,
      user_id:         "user-one",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "locker_002",
      zones:           ["zone-1234"],
      booking_type:    "locker",
      booking_start:   (Time.utc - 5.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "notify",
      description:     "",
      checked_in:      true,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-one",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              3,
      user_id:         "user-one",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "locker_003",
      zones:           ["zone-1234"],
      booking_type:    "locker",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "reject",
      description:     "",
      checked_in:      true,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-one",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              4,
      user_id:         "user-one",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "locker_004",
      zones:           ["zone-1234"],
      booking_type:    "locker",
      booking_start:   (Time.utc - 5.hours).to_unix,
      booking_end:     (Time.utc + 1.hours).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_after_hours",
      description:     "",
      checked_in:      true,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-one",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
  ]

  def query_bookings(
    type : String,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil
  )
    JSON.parse(BOOKINGS.to_json)
  end

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    zones = [
      {
        created_at:   1660537814,
        updated_at:   1681800971,
        id:           "zone-1234",
        name:         "Test Zone",
        display_name: "Test Zone",
        location:     "",
        description:  "",
        code:         "",
        type:         "",
        count:        0,
        capacity:     0,
        map_id:       "",
        tags:         [
          "building",
        ],
        triggers:  [] of String,
        parent_id: "zone-0000",
        timezone:  "Australia/Sydney",
      },
    ]

    JSON.parse(zones.to_json)
  end

  def update_booking(booking_id : String | Int64, booking_end : Int64, checked_in : Bool)
    true
  end
end
