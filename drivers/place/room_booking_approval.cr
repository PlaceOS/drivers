require "placeos-driver"
require "place_calendar"

class Place::RoomBookingApproval < PlaceOS::Driver
  descriptive_name "PlaceOS Room Booking Approval"
  generic_name :RoomBookingApproval
  description %(Room Booking approval for tentative events)

  default_settings({
    check_recurring_event_id: false, # fetches the event to verify the provided id is the series root.
  })

  accessor calendar : Calendar_1

  @check_recurring_event_id : Bool = false

  getter building_id : String { get_building_id.not_nil! }
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  def on_update
    @building_id = nil
    @systems = nil
    @check_recurring_event_id = setting?(Bool, :check_recurring_event_id) || false

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
        begin
          sys = system(system_id)
          if sys.exists?("Bookings", 1)
            if bookings = sys.get("Bookings", 1).status?(Array(PlaceCalendar::Event), "tentative")
              results[system_id] = bookings unless bookings.empty?
            end
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
    calendar.accept_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: event_id)
  end

  @[Security(Level::Support)]
  def accept_recurring_event(calendar_id : String, recurring_event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    recurring_event_id = resolve_recurring_event_id(calendar_id, recurring_event_id, user_id) if @check_recurring_event_id

    logger.debug { "accepting recurring event #{recurring_event_id} on #{calendar_id}" }
    calendar.accept_event(calendar_id: calendar_id, event_id: recurring_event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: recurring_event_id)
  end

  @[Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    calendar.decline_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: event_id)
  end

  @[Security(Level::Support)]
  def decline_recurring_event(calendar_id : String, recurring_event_id : String, user_id : String? = nil, notify : Bool = true, comment : String? = nil)
    recurring_event_id = resolve_recurring_event_id(calendar_id, recurring_event_id, user_id) if @check_recurring_event_id

    logger.debug { "declining recurring event #{recurring_event_id} on #{calendar_id}" }
    calendar.decline_event(calendar_id: calendar_id, event_id: recurring_event_id, user_id: user_id, notify: notify, comment: comment)
    clear_cache(event_id: recurring_event_id)
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
