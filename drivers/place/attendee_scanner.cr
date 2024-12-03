require "placeos-driver"
require "place_calendar"

class Place::AttendeeScanner < PlaceOS::Driver
  descriptive_name "PlaceOS Room Events"
  generic_name :AttendeeScanner

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  default_settings({
    internal_domains: ["comment.out", "use authority / domain email_domains by preference"],
  })

  getter internal_domains : Array(String) = [] of String

  def on_load
    on_update
  end

  def on_update
    # TODO:: use authority email_domains so this setting isn't required
    @internal_domains = setting(Array(String), :internal_domains).map!(&.strip.downcase)

    @building_id = nil
    @timezone = nil
    @systems = nil
    @org_id = nil
  end

  # Grabs the list of systems in the building
  getter systems : Hash(String, Array(String)) do
    locations.systems.get.as_h.transform_values(&.as_a.map(&.as_s))
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  getter org_id : String do
    building_details = staff_api.zone(building_id).get

    if tz = building_details["timezone"].as_s?
      @timezone = Time::Location.load(tz)
    end

    building_details["parent_id"].as_s
  end

  protected getter timezone : Time::Location do
    building_details = staff_api.zone(building_id).get
    @org_id = building_details["parent_id"].as_s?

    tz = building_details["timezone"].as_s
    Time::Location.load(tz)
  end

  alias Event = PlaceCalendar::Event
  alias Attendee = PlaceCalendar::Event::Attendee

  record Guest, zones : Tuple(String, String, String), system_id : String, details : Attendee, event : Event do
    include JSON::Serializable
  end

  # extract the list of externals invited to meetings in the building today
  def externals_in_events
    building = building_id
    externals = [] of Guest

    # get the current time
    now = Time.local(timezone)
    end_of_day = now.at_end_of_day

    # Find all the guests
    systems.each do |level_id, system_ids|
      zones = {org_id, building, level_id}

      system_ids.each do |system_id|
        sys = system(system_id)
        if sys.exists?("Bookings", 1)
          events = sys.get("Bookings", 1).status(Array(Event), :bookings) rescue [] of Event
          events.each do |event|
            # all bookings are sorted in this array
            event_end = event.event_end || end_of_day
            next if event_end <= now
            break if event.event_start >= end_of_day

            externals.concat(event.attendees.reject { |attendee|
              internal_domains.find { |domain| attendee.email.downcase.ends_with? domain }
            }.map { |attendee|
              Guest.new(zones, system_id, attendee, event)
            })
          end
        end
      end
    end

    externals
  end

  record Booking, visitor_email : String, booking_start : Time, booking_end : Time do
    include JSON::Serializable
  end

  # Find the list of external guests expected in the building today
  def externals_booked_to_visit
    building = building_id
    now = Time.local(timezone)
    end_of_day = now.at_end_of_day

    staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {building}, type: "visitor").get.as_a.map do |booking|
      Booking.new(booking["asset_id"].as_s.downcase, Time.unix(booking["booking_start"].as_i64), Time.unix(booking["booking_end"].as_i64))
    end
  end

  # invite missing guests
  def invite_external_guests
    bookings = externals_booked_to_visit
    externals = externals_in_events
    checked = externals.size
    failed = 0

    logger.debug { "found bookings #{bookings.size} and #{externals.size} externals" }

    externals.reject! do |guest|
      guest_email = guest.details.email.downcase
      bookings.find { |booking| booking.visitor_email == guest_email }
    end

    logger.debug { "found #{externals.size} guests without bookings" }

    now = Time.local(timezone)
    end_of_day = now.at_end_of_day

    externals.each do |guest|
      begin
        event = guest.event
        host_email = event.host.as(String).downcase
        host = guest.event.attendees.find! { |attend| attend.email.downcase == host_email }
        guest_email = guest.details.email.downcase
        guest_name = guest.details.name

        sys_info = staff_api.get_system(guest.system_id).get

        staff_api.create_booking(
          booking_type: "visitor",
          asset_id: guest_email,
          user_id: host_email,
          user_email: host_email,
          user_name: host.name,
          zones: guest.zones,
          booking_start: event.event_start.to_unix,
          booking_end: event.event_end.try(&.to_unix) || end_of_day.to_unix,
          checked_in: false,
          approved: true,
          title: guest_name,
          description: event.title,
          time_zone: timezone.name,
          extension_data: {
            name:        guest_name,
            parent_id:   event.id,
            location_id: sys_info["name"].as_s,
          },
          utm_source: "attendee_scanner",
          limit_override: 999,
          event_id: event.id,
          ical_uid: event.ical_uid,
          attendees: [{
            name:  guest_name,
            email: guest_email,
          }]
        ).get
      rescue error
        failed += 1
        logger.warn(exception: error) { "failed to invite guest: #{guest.details.email}" }
      end
    end

    {
      invited: externals.size - failed,
      checked: checked,
      failure: failed,
    }
  end
end
