require "placeos-driver"
require "place_calendar"

class Place::RoomBookingApproval < PlaceOS::Driver
  descriptive_name "PlaceOS Room Booking Approval"
  generic_name :RoomBookingApproval
  description %(Room Booking approval for tentative events)

  default_settings({
    check_recurring_event_id:     false, # fetches the event to verify the provided id is the series root.
    check_bookings_every_minutes: 2,
    refresh_debounce_seconds:     10,    # seconds to wait before triggering Bookings poll after an approval action.
    disable_refresh_bookings:     false, # set to true to skip the debounced Bookings re-poll entirely.
  })

  accessor calendar : Calendar_1

  @check_recurring_event_id : Bool = false
  @booking_poll_rate : UInt32 = 2
  @refresh_debounce : UInt32 = 10
  @disable_refresh_bookings : Bool = false
  @pending_refresh : Set(String) = Set(String).new
  @refresh_scheduled : Bool = false

  # ameba:disable Lint/NotNil
  getter building_id : String { get_building_id.not_nil! }
  # ameba:disable Lint/NotNil
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  def on_update
    @building_id = nil
    @systems = nil
    @check_recurring_event_id = setting?(Bool, :check_recurring_event_id) || false
    @booking_poll_rate = setting?(UInt32, :check_bookings_every_minutes) || 2_u32
    @refresh_debounce = setting?(UInt32, :refresh_debounce_seconds) || 10_u32
    @disable_refresh_bookings = setting?(Bool, :disable_refresh_bookings) || false

    schedule.clear
    @pending_refresh.clear
    @refresh_scheduled = false
    # used to detect changes in building configuration
    schedule.every(1.hour) { @systems = get_systems_list.not_nil! } # ameba:disable Lint/NotNil

    # The search
    schedule.every(@booking_poll_rate.minutes) { find_bookings_for_approval }
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

    systems.each do |_level_id, system_ids|
      system_ids.each do |system_id|
        begin
          sys = system(system_id)
          if sys.exists?("Bookings", 1)
            bookings = sys.get("Bookings", 1).status?(Array(PlaceCalendar::Event), "tentative")
            next unless bookings
            bookings.select! { |event| event.status == "tentative" }
            results[system_id] = bookings unless bookings.empty?
          end
        rescue error
          logger.warn(exception: error) { "unable to parse tentative bookings for #{system_id}" }
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
  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    affected_systems = find_affected_systems(event_id)
    calendar.accept_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: event_id)
    refresh_bookings(affected_systems)
  end

  @[Security(Level::Support)]
  def accept_recurring_event(calendar_id : String, recurring_event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    recurring_event_id = resolve_recurring_event_id(calendar_id, recurring_event_id, user_id) if @check_recurring_event_id

    logger.debug { "accepting recurring event #{recurring_event_id} on #{calendar_id}" }
    affected_systems = find_affected_systems(recurring_event_id)
    calendar.accept_event(calendar_id: calendar_id, event_id: recurring_event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: recurring_event_id)
    refresh_bookings(affected_systems)
  end

  @[Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    affected_systems = find_affected_systems(event_id)
    calendar.decline_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: event_id)
    refresh_bookings(affected_systems)
  end

  @[Security(Level::Support)]
  def decline_recurring_event(calendar_id : String, recurring_event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    recurring_event_id = resolve_recurring_event_id(calendar_id, recurring_event_id, user_id) if @check_recurring_event_id

    logger.debug { "declining recurring event #{recurring_event_id} on #{calendar_id}" }
    affected_systems = find_affected_systems(recurring_event_id)
    calendar.decline_event(calendar_id: calendar_id, event_id: recurring_event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: recurring_event_id)
    refresh_bookings(affected_systems)
  end

  # Returns the system IDs whose cached tentative events match the given
  # event_id (by event id or recurring_event_id).  Must be called *before*
  # clear_cache so the cache still contains the events.
  protected def find_affected_systems(event_id : String) : Array(String)
    cache = self[:approval_required]? ? ApprovalCache.from_json(self[:approval_required].to_json) : ApprovalCache.new
    cache.compact_map do |system_id, events|
      system_id if events.any? { |event| event.id == event_id || event.recurring_event_id == event_id }
    end
  end

  # Queues the given system IDs for a debounced Bookings re-poll.
  # Multiple calls within the 10-second window are batched into a
  # single poll_events call per affected system, giving the calendar
  # provider time to propagate the status change.
  protected def refresh_bookings(system_ids : Array(String))
    return if @disable_refresh_bookings
    @pending_refresh.concat(system_ids)
    return if @refresh_scheduled
    @refresh_scheduled = true
    schedule.in(@refresh_debounce.seconds) { perform_refresh }
  end

  # Drains the pending set and triggers poll_events on each system.
  protected def perform_refresh
    system_ids = @pending_refresh.dup
    @pending_refresh.clear
    @refresh_scheduled = false

    system_ids.each do |system_id|
      begin
        sys = system(system_id)
        sys.get("Bookings", 1).poll_events if sys.exists?("Bookings", 1)
      rescue error
        logger.warn(exception: error) { "unable to trigger poll_events on Bookings in #{system_id}" }
      end
    end
  end

  @[Security(Level::Support)]
  def resolve_recurring_event_id(calendar_id : String, event_id : String, user_id : String? = nil) : String
    event_user_id = user_id || calendar_id
    response = calendar.get_event(user_id: event_user_id, id: event_id, calendar_id: calendar_id).get
    place_event = PlaceCalendar::Event.from_json(response.to_json)
    if (recurring_event_id = place_event.recurring_event_id.presence) && recurring_event_id != event_id
      logger.debug { "provided id #{event_id} is a series occurrence, not the recurring event — using recurring event id #{recurring_event_id}" }
      recurring_event_id
    else
      event_id
    end
  rescue error
    logger.debug(exception: error) { "unable to verify recurring event id for #{event_id}" }
    event_id
  end
end
