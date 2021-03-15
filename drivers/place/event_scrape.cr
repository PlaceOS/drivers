require "place_calendar"

class Place::EventScrape < PlaceOS::Driver
  descriptive_name "PlaceOS Event Scrape"
  generic_name :EventScrape

  default_settings({
    zone_ids: ["placeos-zone-id"],
    internal_domains: ["PlaceOS.com"],
    poll_interval: 5
  })

  accessor staff_api : StaffAPI_1

  @zone_ids = [] of String
  @internal_domains = [] of String
  @poll_interval : Time::Span = 5.minutes

  alias Event = PlaceCalendar::Event

  struct SystemWithEvents
    include JSON::Serializable

    def initialize(@name : String, @zones : Array(String), @events : Array(Event))
    end
  end

  def on_load
    on_update
  end

  def on_update
    schedule.clear

    @zone_ids = setting?(Array(String), :zone_ids) || [] of String
    @internal_domains = setting?(Array(String), :internal_domains) || [] of String
    @poll_interval = (setting?(UInt32, :poll_interval) || 5).minutes
  end

  def get_bookings
    response = {
      internal_domains: @internal_domains,
      systems: {} of String => SystemWithEvents
    }

    logger.debug { "Getting bookings for zones" }
    logger.debug { @zone_ids.inspect }

    @zone_ids.each do |z_id|
      staff_api.systems(zone_id: z_id).get.as_a.each do |sys|
        sys_id = sys["id"].as_s
        # In case the same system is in multiple zones
        next if response[:systems][sys_id]?

        response[:systems][sys_id] = SystemWithEvents.new(
          name: sys["name"].as_s,
          zones: Array(String).from_json(sys["zones"].to_json),
          events: get_system_bookings(sys_id)
        )
      end
    end

    response
  end

  def get_system_bookings(sys_id : String) : Array(Event)
    booking_module = staff_api.modules_from_system(sys_id).get.as_a.find { |mod| mod["name"] == "Bookings" }
    # If the system has a booking module with bookings
    if booking_module && (bookings = staff_api.get_module_state(booking_module["id"].as_s).get["bookings"]?)
      JSON.parse(bookings.as_s).as_a.map { |b| Event.from_json(b.to_json) }
    else
      [] of Event
    end
  end
end
