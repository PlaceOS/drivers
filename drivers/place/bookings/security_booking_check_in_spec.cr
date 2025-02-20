require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::SecurityBookingCheckin" do
  system({
    StaffAPI: {StaffAPIMock},
  })

  exec(:door_event, {
    module_id:       "mod-123",
    security_system: "gallagher",
    door_id:         "door 123",
    timestamp:       0,
    action:          "Granted",
    user_email:      "user@email.com",
  }.to_json).get

  exec(:event_count).get.should eq 1
  exec(:check_ins).get.should eq 1
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def user(id : String)
    raise "unknown user #{id}" unless id == "user@email.com"
    {
      email:      "user@email.com",
      login_name: "user@email.com",
    }
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
    deleted : Bool? = nil
  )
    raise "unexpected bookings query" unless type == "desk" && zones.includes?("zone-building") && email == "user@email.com"

    [{
      id:         2345,
      checked_in: false,
    }]
  end

  def booking_check_in(booking_id : String | Int64, state : Bool = true, utm_source : String? = nil, instance : Int64? = nil)
    raise "unexpected booking id" unless booking_id == 2345 && state
    true
  end

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    raise "unexpected tag" unless tags == "building"
    [{
      "id" => "zone-building",
    }]
  end
end
