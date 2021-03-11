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

  def on_load
    on_update
  end

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
    logger.debug { "System ids from zones" }
    logger.debug { system_ids.inspect }

    # Select only the sytem ids that have a booking module
    booking_module_ids = [] of String
    system_ids.each { |sys_id|
      # Only look for the first booking module
      booking_module = staff_api.modules_from_system(sys_id).get.as_a.find { |mod| mod["name"] == "Bookings" }
      booking_module_ids |= [booking_module["id"].as_s] if booking_module
    }
    logger.debug { "Booking module ids" }
    logger.debug { booking_module_ids.inspect }

    # Get all of the bookings from each booking module
    bookings = booking_module_ids.flat_map { |mod_id|
      logger.debug { "Getting bookings for module #{mod_id}" }
      b = staff_api.get_module_state(mod_id, "bookings").get.as_a
      logger.debug { b.inspect }
      b
    }
    logger.debug { "Bookings" }
    logger.debug { bookings.inspect }
  end
end
