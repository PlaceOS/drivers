require "placeos"

class Place::GuestScrape < PlaceOS::Driver
  descriptive_name "PlaceOS Guest Scrape"
  generic_name :GuestScrape

  default_settings({
    zone_ids: ["placeos-zone-id"],
    internal_domains: ["PlaceOS.com"],
    poll_interval: 5
  })

  accessor staff_api : StaffAPI_1

  @zone_ids = [] of String
  @internal_domains = [] of String
  @poll_interval : Time::Span = 5.minutes

  def on_update
    schedule.clear

    @zone_ids = setting?(Array(String), :zone_ids) || [] of String
    @internal_domains = setting?(Array(String), :zone_ids) || [] of String
    @poll_interval = (setting?(UInt32, :poll_interval) || 5).minutes
  end

  def get_bookings
    logger.debug { "Getting bookings for zones" }
    logger.debug { @zone_ids.inspect }

    # Get all the system ids from the zones in @zone_ids
    system_ids = [] of String
    @zone_ids.each do |z_id|
      # Use array union to prevent dupes incase the same system is in multiple zones
      staff_api.systems(zone_id: z_id).get.as_a.each { |sys| system_ids |= [sys["id"].as_s] }
    end

    # Select only the sytem ids that have a booking module
    systems_ids_with_booking_modules = system_ids.select { |sys_id|
      staff_api.modules_from_system(sys_id).get.as_a.any? { |mod|
        mod["name"] == "Bookings"
      }
    }
  end
end
