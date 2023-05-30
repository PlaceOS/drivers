require "placeos-driver/spec"
require "placeos-driver/interface/locatable"

WIRELESS_LOC = {
  "location"         => "wireless",
  "coordinates_from" => "bottom-left",
  "x"                => 16.764784482481577,
  "y"                => 25.435735950388988,
  "lng"              => 55.274935030154325,
  "lat"              => 25.201036346211698,
  "variance"         => 7.944837533996209,
  "last_seen"        => 1601526474,
  "building"         => "zone_1234",
  "level"            => "zone_1234",
}

DESK_LOC = {
  "location"    => "desk",
  "at_location" => true,
  "map_id"      => "desk-4-1006",
  "building"    => "zone_1234",
  "level"       => "zone_1234",
}

DriverSpecs.mock_driver "Place::LocationServices" do
  system({
    Dashboard:      {WirelessLocation},
    DeskManagement: {DeskLocation},
  })

  exec(:locate_user, "Steve").get.should eq([WIRELESS_LOC, DESK_LOC])
end

# :nodoc:
class WirelessLocation < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Locatable

  def locate_user(email : String? = nil, username : String? = nil)
    [WIRELESS_LOC]
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    [] of String
  end

  alias OwnershipMAC = NamedTuple(
    location: String,
    assigned_to: String,
    mac_address: String,
  )

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    nil
  end
end

# :nodoc:
class DeskLocation < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Locatable

  def locate_user(email : String? = nil, username : String? = nil)
    [DESK_LOC]
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    [] of String
  end

  alias OwnershipMAC = NamedTuple(
    location: String,
    assigned_to: String,
    mac_address: String,
  )

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    nil
  end
end
