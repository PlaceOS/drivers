require "placeos-driver"
require "place_calendar"

# Filters Bookings event cache down to public events for unauthenticated access.
# Uses the Calendar driver for guest registration.
class Place::PublicEvents < PlaceOS::Driver
  descriptive_name "PlaceOS Public Events"
  generic_name :PublicEvents
  description %(Caches public events for external access and handles guest registration)

  accessor bookings : Bookings_1
  accessor calendar : Calendar_1

  @all_bookings : Array(PlaceCalendar::Event) = [] of PlaceCalendar::Event
  @public_event_ids : Set(String) = Set(String).new

  bind Bookings_1, :bookings, :on_bookings_change

  private def on_bookings_change(_subscription, new_value : String)
    @all_bookings = Array(PlaceCalendar::Event).from_json(new_value)
    filter_and_cache
  rescue error
    logger.warn(exception: error) { "failed to process bookings update" }
  end

  private def filter_and_cache : Array(PlaceCalendar::Event)
    public_events = @all_bookings.select do |event|
      event.extended_properties.try { |props| props["public"]? == "true" }
    end
    @public_event_ids = public_events.compact_map(&.id).to_set
    self["public_events"] = public_events.map { |e| PublicEvent.new(e) }
    public_events
  end

  # Forces a Bookings re-poll then re-applies the public filter.
  @[Security(Level::Administrator)]
  def update_public_events : Nil
    bookings.poll_events.get
  end

  # Appends an external attendee to the calendar event.
  def register_attendee(event_id : String, name : String, email : String) : Bool
    unless @public_event_ids.includes?(event_id)
      logger.warn { "#{event_id} is not a known public event" }
      return false
    end

    cal_id = system.email.presence
    unless cal_id
      logger.error { "system has no calendar email configured" }
      return false
    end

    event_data = calendar.get_event(cal_id, event_id).get
    unless event_data
      logger.warn { "event #{event_id} not found in calendar" }
      return false
    end

    event = PlaceCalendar::Event.from_json(event_data.to_json)
    event.attendees << PlaceCalendar::Event::Attendee.new(name: name, email: email)
    calendar.update_event(event, calendar_id: cal_id).get
    true
  end

  # Fields that are safe to expose publicly.
  private struct PublicEvent
    include JSON::Serializable

    getter id : String?
    getter title : String?
    getter event_start : Int64
    getter event_end : Int64?
    getter location : String?
    getter timezone : String?
    getter? all_day : Bool

    def initialize(event : PlaceCalendar::Event)
      @id = event.id
      @title = event.title
      @event_start = event.event_start.to_unix
      @event_end = event.event_end.try(&.to_unix)
      @location = event.location
      @timezone = event.timezone
      @all_day = event.all_day?
    end
  end
end
