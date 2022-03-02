require "set"
require "placeos-driver"
require "./kio_cloud_models"

class KontaktIO::ContactTracing < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Kontakt Contact Tracing"
  generic_name :ContactTracing

  accessor kontakt : KontaktIO_1
  accessor location_services : LocationServices_1

  def close_contacts(email : String? = nil, username : String? = nil, start_time : Int64? = nil, end_time : Int64? = nil)
    macs = location_services.macs_assigned_to(email, username).get.as_a.map(&.as_s)

    # obtain the raw contact information
    locations = [] of Tracking
    macs.each do |mac|
      begin
        raw_report = kontakt.colocations(mac, start_time, end_time).get.to_json
        locations.concat Array(Tracking).from_json(raw_report)
      rescue error
        logger.warn(exception: error) { "locating close contacts" }
      end
    end

    # find all the unique mac addresses in the results
    macs = Set(String).new
    locations.each { |location| macs << location.mac_address }

    # map the mac addresses to people where we can (usernames in this case)
    mac_mappings = {} of String => String
    macs.each do |mac|
      mac = format_mac(mac)
      if owner = location_services.check_ownership_of(mac).get
        username = owner["assigned_to"]?.try(&.as_s)
        next unless username
        mac_mappings[mac] = username
      end
    end

    # Generate the contact tracing results
    locations.map do |location|
      mac = format_mac(location.mac_address)
      username = mac_mappings[mac]?
      {
        mac_address:  mac,
        username:     username,
        contact_time: location.start_time.to_unix,
        # duration in seconds
        duration: location.duration,
      }
    end
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
