require "placeos-driver"
require "place_calendar"

class Place::RoomBookingApprovalAltnerative < PlaceOS::Driver
  descriptive_name "PlaceOS Room Booking Approval (alternative 1)"
  generic_name :RoomBookingApproval
  description %(Room Booking approval for events where the room has not responded)

  default_settings({
    notify_host_on_accept: true,
    notify_host_on_decline: true,
    default_accept_message: "Request accepted",
    default_decline_message: "Request not accepted",
    events_requiring_approval_are_tentative: true
  })


  accessor calendar : Calendar_1

  getter building_id : String { get_building_id.not_nil! }
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  @notify_host_on_accept : Bool = true
  @notify_host_on_decline : Bool = true
  @default_accept_message : String = "Request accepted"
  @default_decline_message : String = "Request not accepted"
  @events_requiring_approval_are_tentative : Bool = true

  def on_load
    on_update
  end

  def on_update
    @building_id = nil
    @systems = nil

    schedule.clear
    # used to detect changes in building configuration
    schedule.every(1.hour) { @systems = get_systems_list.not_nil! }

    # The search
    schedule.every(5.minutes) { find_bookings_for_approval }

    @notify_host_on_accept = setting?(Bool, :notify_host_on_accept) || true
    @notify_host_on_decline = setting?(Bool, :notify_host_on_decline) || true
    @default_accept_message = setting?(String, :default_accept_message) || "Request accepted"
    @default_decline_message = setting?(String, :default_decline_message) || "Request not accepted"
    @events_requiring_approval_are_tentative = setting?(Bool, :events_requiring_approval_are_tentative) || true
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
            @events_requiring_approval_are_tentative ? 
              bookings.select! { |event| event.status == "tentative" }
              : bookings.select! { |booking| room_attendee(booking).try(&.response_status).in?({"needsAction", "tentative"}) }
            results[system_id] = bookings unless bookings.empty?
          end
        end
      end
    end

    self[:approval_required] = results
  end

  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool? = nil, comment : String? = nil)
    calendar.accept_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify || @notify_host_on_accept, comment: comment || @default_accept_message)
  end

  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool? = nil, comment : String? = nil)
    calendar.decline_event(calendar_id: calendar_id, event_id: event_id, user_id: user_id, notify: notify || @notify_host_on_decline, comment: comment || @default_decline_message)
  end

  private def room_attendee(event : PlaceCalendar::Event)
    event.attendees.find { |a| a.resource } || event.attendees.last
  end
end
