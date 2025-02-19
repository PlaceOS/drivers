require "placeos-driver/spec"

DriverSpecs.mock_driver "InnerRange::IntegritiHIDVirtualPass" do
  system({
    StaffAPI:  {StaffAPIMock},
    Integriti: {IntegritiMock},
  })

  sleep 1.second

  exec(:check_ins).get.should eq 1
  exec(:last_changed).get.should eq "2025-02-18T23:13:05.000000000"
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
    return [] of Nil if type == "desk"
    raise "unexpected bookings query" unless type == "parking" && zones.includes?("zone-building") && email == "user@email.com"

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

# :nodoc:
class IntegritiMock < DriverSpecs::MockDriver
  @users = {
    "U35" => {
      "id"   => 281474976710691,
      "name" => "Test User",
      "site" => {
        id:   1,
        name: "PlaceOS",
      },
      "address"      => "U35",
      "partition_id" => 0,
      "not_origo"    => false, # just so the hash accepts bools
      "email"        => "user@email.com",
    },
  }

  def users(site_id : Int32? = nil, email : String? = nil, first_name : String? = nil, second_name : String? = nil)
    name = "#{first_name} #{second_name}"
    @users.values.select { |user| user["name"] == name }
  end

  @responded : Bool = false

  def review_predefined_access(query_id : String | Int64, long_poll : Bool = false, after : String | Int64 | Time? = nil, page_limit : Int64? = nil)
    # this emulates the long polling behaviour of integriti
    if @responded
      sleep 10.seconds
      return [] of Nil
    end

    @responded = true
    [{
      "id"             => "0b6f2584-865a-42f6-a939-5fd2e1ed45",
      "text"           => "Test User License Plate access at <R04:Rdr01> into B4 Carpark Entry Roller ANPR Camera 8977993759162 [License Plate CZG152]",
      "time_generated" => "2025-02-18T23:13:05Z",
      "event_type"     => "UserAccess",
      "transition"     => "UserGrantedIn",
      "time_gen_ms"    => "2025-02-18T23:13:05.000000000",
    },
     {
       "id"             => "bd436fe9-64dd-429b-a6a5-41f4e21a99",
       "text"           => "EA Kia EV6 Pool Car License Plate access at <R07:Rdr01> out of B8 - B4 Carpark Ramp Exit ANPR Camera 89779938759161 [License Plate 2BI8AZ]",
       "time_generated" => "2025-02-18T23:04:52Z",
       "event_type"     => "UserAccess",
       "transition"     => "UserGrantedOut",
       "time_gen_ms"    => "2025-02-18T23:04:52.859000000",
     }]
  end
end
