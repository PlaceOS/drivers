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

  def find_bookings_for_approval : Hash(String, Array(PlaceCalendar::Event))
    results = {} of String => Array(PlaceCalendar::Event)

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
  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    calendar.accept_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
  end

  @[Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    calendar.decline_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify, comment: comment)
  end
end
