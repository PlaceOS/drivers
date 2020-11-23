module Place; end

require "placeos-driver/interface/locatable"

class Place::LocationServices < PlaceOS::Driver
  descriptive_name "PlaceOS Location Services"
  generic_name :LocationServices
  description %(collects location data from compatible services and combines the data)

  # Runs through all the services that support the Locatable interface
  # requests location information on the identifier for all of them
  # concatenates the results and returns them as a single array
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }
    located = [] of JSON::Any
    system.implementing(Interface::Locatable).locate_user(email, username).get.each do |locations|
      located.concat locations.as_a
    end
    located
  end

  # Will return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil)
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }
    macs = [] of String
    system.implementing(Interface::Locatable).macs_assigned_to(email, username).get.each do |found|
      macs.concat found.as_a.map(&.as_s)
    end
    macs
  end

  # Will return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String)
    logger.debug { "searching for owner of #{mac_address}" }
    owner = nil
    system.implementing(Interface::Locatable).check_ownership_of(mac_address).get.each do |result|
      if result != nil
        owner = result
        break
      end
    end
    owner
  end

  # Will return an array of devices and their x, y coordinates
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    located = [] of JSON::Any
    system.implementing(Interface::Locatable).device_locations(zone_id, location).get.each do |locations|
      located.concat locations.as_a
    end
    located
  end
end
