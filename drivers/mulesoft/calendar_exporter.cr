require "./models"
require "placeos-driver"
require "place_calendar"

class MuleSoft::CalendarExporter < PlaceOS::Driver
  descriptive_name "MuleSoft Bookings to Calendar Events Exporter"
  generic_name :Bookings
  description %(Retrieves and creates bookings using the MuleSoft API)

  default_settings({
    calendar_time_zone: "Australia/Sydney",
  })

  accessor calendar : Calendar_1

  @time_zone_string : String | Nil = "Australia/Sydney"
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @bookings : Array(Hash(String, Int64 | String | Nil)) = [] of Hash(String, Int64 | String | Nil)
  @existing_events : Array(JSON::Any) = [] of JSON::Any
  # An array of Attendee that has only the system (room) email address. Generally static
  @just_this_system : NamedTuple(email: String, name: String) = {email: "", name: ""}

  def on_load
    @just_this_system = {
      "email": system.email.not_nil!,
      "name":  system.name,
    }
    on_update
  end

  def on_update
    subscriptions.clear

    @time_zone_string = setting?(String, :calendar_time_zone).presence
    @time_zone = Time::Location.load(@time_zone_string.not_nil!) if @time_zone_string
    self[:timezone] = Time.local.to_s

    subscription = system.subscribe(:Bookings_1, :bookings) do |_subscription, mulesoft_bookings|
      logger.debug { "DETECTED changed in Mulesoft Bookings.." }
      @bookings = Array(Hash(String, Int64 | String | Nil)).from_json(mulesoft_bookings)
      logger.debug { "#{@bookings.size} bookings in total" }

      update_events
      @bookings.each { |b| export_booking(b) }
    end
  end

  def status
    {
      "bookings": @bookings,
      "events":   @existing_events,
    }
  end

  def update_events
    logger.debug { "FETCHING existing Calendar events..." }
    @existing_events = fetch_events()
    logger.debug { "#{@existing_events.size} events in total" }
  end

  protected def fetch_events(past_span : Time::Span = 14.days, future_span : Time::Span = 14.days)
    now = Time.local @time_zone
    from = now - past_span
    til = now + future_span

    calendar.list_events(
      calendar_id: system.email.not_nil!,
      period_start: from.to_unix,
      period_end: til.to_unix
    ).get.as_a
  end

  protected def export_booking(booking : Hash(String, Int64 | String | Nil))
    # Mulesoft booking titles are often nil. Use the body instead in this case
    booking["title"] = booking["body"] if booking["title"].nil?
    booking["title"] = "#{booking["recurring_master_id"]} #{booking["title"]}"
    logger.debug { "Checking for existing events that match: #{booking}" }

    unless event_already_exists?(booking, @existing_events)
      new_event = {
        title:       booking["title"],
        event_start: booking["event_start"],
        event_end:   booking["event_end"],
        timezone:    @time_zone_string,
        description: booking["body"],
        user_id:     system.email.not_nil!,
        attendees:   [@just_this_system],
        location:    system.name.not_nil!,
      }
      logger.debug { ">>> EXPORTING booking #{new_event}" }
      calendar.create_event(**new_event)
    end
  end

  protected def event_already_exists?(new_event : Hash(String, Int64 | String | Nil), existing_events : Array(JSON::Any))
    existing_events.each do |existing_event|
      return true if events_match?(new_event, existing_event.as_h)
    end
    false
  end

  protected def events_match?(event_a : Hash(String, Int64 | String | Nil), event_b : Hash(String, JSON::Any))
    event_a.select("event_start", "event_end", "title") == event_b.select("event_start", "event_end", "title")
  end

  def delete_all_events(past_days : Int32 = 14, future_days : Int32 = 14)
    events = fetch_events(past_span: past_days.days, future_span: future_days.days)
    event_ids = events.map { |e| e["id"] }
    event_ids.each do |event_id|
      calendar.delete_event(calendar_id: system.email.not_nil!, event_id: event_id)
    end
    "Deleted #{event_ids.size} events"
  end
end
