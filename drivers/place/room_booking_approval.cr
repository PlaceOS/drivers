require "placeos-driver"
require "place_calendar"

class Place::RoomBookingApproval < PlaceOS::Driver
  descriptive_name "PlaceOS Room Booking Approval"
  generic_name :RoomBookingApproval
  description %(Room Booking approval for tentative events)

  default_settings({} of String => String)

  accessor calendar : Calendar_1

  getter building_id : String { get_building_id.not_nil! }
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  def on_update
    @building_id = nil
    @systems = nil

    schedule.clear
    # used to detect changes in building configuration
    schedule.every(1.hour) { @systems = get_systems_list.not_nil! }

    # The search
    schedule.every(5.minutes) { find_bookings_for_approval }
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = system["StaffAPI"].zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  # Grabs the list of systems in the building
  def get_systems_list
    system["StaffAPI"].systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  rescue error
    logger.warn(exception: error) { "unable to obtain list of systems in the building" }
    nil
  end

  alias ApprovalCache = Hash(String, Array(PlaceCalendar::Event))

  def find_bookings_for_approval : ApprovalCache
    results = ApprovalCache.new

    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        sys = system(system_id)
        if sys.exists?("Bookings", 1)
          if bookings = sys.get("Bookings", 1).status?(Array(PlaceCalendar::Event), "bookings")
            bookings.select! { |event| event.status == "tentative" }
            results[system_id] = bookings unless bookings.empty?
          end
        end
      end
    end

    self[:approval_required] = results
  end

  @[Security(Level::Support)]
  def clear_cache(event_id : String? = nil)
    if event_id
      cache = self[:approval_required]? ? ApprovalCache.from_json(self[:approval_required].to_json) : ApprovalCache.new
      new_cache = ApprovalCache.new
      cache.each do |system_id, events|
        new_cache[system_id] = events.reject { |event| event.id == event_id || event.recurring_event_id == event_id }
      end

      self[:approval_required] = new_cache
    else
      self[:approval_required] = ApprovalCache.new
    end
  end

  @[Security(Level::Support)]
  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    calendar.accept_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: event_id)
  end

  @[Security(Level::Support)]
  def accept_recurring_event(calendar_id : String, recurring_event_id : String, user_id : String? = nil, period_start : Int64? = nil, period_end : Int64? = nil, notify : Bool = false, comment : String? = nil)
    logger.debug { "accepting recurring event #{recurring_event_id} on #{calendar_id}" }

    if period_start || period_end
      # Use provided dates or default to now and 1 year ahead
      now = Time.utc
      start_time = period_start || now.to_unix
      end_time = period_end || (now + 1.year).to_unix

      # Find all instances of this recurring event
      events = Array(PlaceCalendar::Event).from_json calendar.list_events(
        calendar_id: calendar_id,
        period_start: start_time,
        period_end: end_time,
        user_id: user_id,
        include_cancelled: false
      ).get.to_json
      logger.debug { "Found #{events.size} events on calendar #{calendar_id}" }

      recurring_instances = events.select { |event| event.recurring_event_id == recurring_event_id }
      logger.info { "Found #{recurring_instances.size} instances of recurring event #{recurring_event_id}" }

      # Accept each instance
      accepted_count = 0
      recurring_instances.each do |event|
        begin
          calendar.accept_event(calendar_id, event.id, user_id: user_id, notify: notify, comment: comment)
          accepted_count += 1
          logger.debug { "Accepted recurring event instance #{event.id}" }
        rescue error
          logger.warn(exception: error) { "Failed to accept recurring event instance #{event.id}" }
        end
      end

      logger.info { "Accepted #{accepted_count} instances of recurring event #{recurring_event_id}" }
    else
      calendar.accept_event(calendar_id: calendar_id, event_id: recurring_event_id, user_id: user_id, notify: notify, comment: comment)
    end

    clear_cache(event_id: recurring_event_id)
  end

  @[Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    calendar.decline_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
  end
end
