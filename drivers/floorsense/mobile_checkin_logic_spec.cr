require "placeos-driver/spec"

DriverSpecs.mock_driver "Floorsense::MobileCheckinLogic" do
  system({
    FloorsenseBookingSync: {FloorsenseBookingSyncMock},
    StaffAPI:              {StaffAPIMock},
  })

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("checked-in")

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("adhoc")

  resp = exec(:eui64_scanned, "euid-rand-chars", "test-user").get
  resp.should eq("forbidden")
end

# :nodoc:
class FloorsenseBookingSyncMock < DriverSpecs::MockDriver
  def eui64_to_desk_id(id : String)
    {level: "level_zone", desk_id: "place_desk", building_id: "building_zone"}
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @query_count : Int32 = 0

  def query_bookings(type : String, zones : Array(String))
    @query_count += 1
    case @query_count
    when 1
      [{id: 1234, asset_id: "place_desk", user_id: "test-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix}]
    when 2
      [] of Nil
    when 3
      # desk owned by a different user
      [{id: 1234, asset_id: "place_desk", user_id: "other-user", checked_in: false, booking_start: 1.minute.ago.to_unix, booking_end: 10.minutes.from_now.to_unix}]
    end
  end

  def booking_check_in(booking_id : String | Int64, check_in : Bool)
    raise "wrong booking_id #{booking_id} or check_in state #{check_in}" unless booking_id == 1234 && check_in
    true
  end

  def metadata(zone_id : String, asset_type : String)
    {
      desks: {
        details: [{id: "place_desk", name: "Cool Desk", features: ["standing"]}],
      },
    }
  end

  def user(user_id : String)
    raise "unexpected user #{user_id}" unless user_id == "test-user"
    {
      id:    "test-user",
      email: "email@org.com",
      name:  "Bob Jane",
    }
  end

  def update_booking(booking_id : String | Int64, booking_end : Int64, checked_in : Bool)
    true
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64,
    booking_end : Int64,
    checked_in : Bool,
    title : String,
    approved : Bool,
    time_zone : String,
    extension_data : Hash(String, JSON::Any)
  )
    raise "bad data" unless user_id == "test-user" && asset_id == "place_desk"
    raise "bad data2" unless checked_in && title == "Cool Desk" && extension_data["deskAttributes"].as_a.map(&.as_s) == ["standing"]
    true
  end
end
