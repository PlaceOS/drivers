require "place_calendar"

class Place::EventScrape < PlaceOS::Driver
  descriptive_name "PlaceOS Guest Scrape"
  generic_name :EventScrape

  default_settings({
    zone_ids: ["placeos-zone-id"],
    internal_domains: ["PlaceOS.com"],
    poll_interval: 5
  })

  accessor staff_api : StaffAPI_1
  accessor mailer : VisitorMailer_1

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

    # Mapping of system_ids to booking_module_ids
    booking_module_ids = {} of String => String
    system_ids.each { |sys_id|
      # Only look for the first booking module
      next unless booking_module = staff_api.modules_from_system(sys_id).get.as_a.find { |mod| mod["name"] == "Bookings" }
      booking_module_ids[sys_id] = booking_module["id"].as_s
    }
    logger.debug { "Booking module ids" }
    logger.debug { booking_module_ids.inspect }

    # Get bookings for each room
    bookings_by_room = {} of String => Array(PlaceCalendar::Event)
    booking_module_ids.each { |sys_id, mod_id|
      next unless bookings = staff_api.get_module_state(mod_id).get["bookings"]?
      bookings = JSON.parse(bookings.as_s).as_a.map { |b| PlaceCalendar::Event.from_json(b.to_json) }
      logger.debug { bookings.inspect }
      bookings_by_room[sys_id] = bookings
    }
    bookings_by_room
  end

  def send_qr_emails
    get_bookings.each do |sys_id, bookings|
      bookings.each do |b|
        b.attendees.each do |a|
          # TODO: confirm if I can always assume the below
          # Don't send to the room since the room is the host of the booking
          next if a.email == b.creator
          params = {
            visitor_email: a.email,
            visitor_name: a.name,
            host_email: b.creator,
            event_id: b.id,
            event_start: b.event_start,
            system_id: sys_id
          }
          logger.debug { "Sending email with:" }
          logger.debug { params.inspect }
          result = mailer.send_visitor_qr_email(
            visitor_email: a.email,
            visitor_name: a.name,
            host_email: b.creator,
            event_id: b.id,
            event_start: b.event_start.to_unix,
            system_id: sys_id
          )
          logger.debug { "Result = #{result.get}" }
        end
      end
    end
  end
end
