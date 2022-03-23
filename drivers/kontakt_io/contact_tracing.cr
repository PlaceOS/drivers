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

    # break all the requests to kontakt into 24 hour segments to avoid requesting too much data
    periods = [] of Tuple(Int64, Int64)
    period_start = start_time || 2.days.ago.to_unix
    period_end = end_time || 1.days.ago.to_unix
    loop do
      temp_ending = period_start + 24.hours.to_i
      if temp_ending < period_end
        periods << {period_start, temp_ending}
      else
        periods << {period_start, period_end}
        break
      end
      period_start = temp_ending + 1
    end

    # obtain the raw contact information
    locations = [] of Tracking
    errors = [] of Exception
    macs.each do |mac|
      begin
        periods.each do |(starting, ending)|
          raw_report = kontakt.colocations(mac, starting, ending).get.to_json
          locations.concat Array(Tracking).from_json(raw_report)
        end
      rescue error
        logger.warn(exception: error) { "locating close contacts" }
        errors << error
      end
    end

    raise errors[0] if locations.empty? && errors.size > 0

    # find all the unique mac addresses in the results
    macs = Set(String).new
    locations.each { |location| macs << location.mac_address }

    # map the mac addresses to people where we can (usernames in this case)
    mac_mappings = {} of String => String
    macs.each do |mac|
      mac = format_mac(mac)
      if owner = location_services.check_ownership_of(mac).get.as_h?
        username = owner["assigned_to"]?.try(&.as_s)
        next unless username
        mac_mappings[mac] = username
      end
    end

    # Generate the contact tracing results
    contacts = {} of String => NamedTuple(
      mac_address: String,
      username: String?,
      contact_time: Int64,
      duration: Int32,
    )

    # removes duplications
    locations.each do |location|
      mac = format_mac(location.mac_address)
      username = mac_mappings[mac]?
      duration = location.duration

      if current = contacts[username || mac]?
        next if current[:duration] > duration
      end

      contacts[username || mac] = {
        mac_address:  mac,
        username:     username,
        contact_time: location.start_time.to_unix,
        # duration in seconds
        duration: duration,
      }
    end

    contacts.values
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
