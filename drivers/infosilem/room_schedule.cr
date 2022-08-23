require "placeos-driver"
require "./models"

class Infosilem::RoomSchedule < PlaceOS::Driver
  descriptive_name "Infosilem Room Schedule Logic"
  generic_name :RoomSchedule
  description %(Polls Infosilem Campus Module to expose bookings relevant for the selected System)

  default_settings({
    infosilem_room_id: "set Infosilem Room ID here",
    polling_cron:      "*/15 * * * *",
    debug:             false
  })

  accessor infosilem : Campus_1

  @room_id : String = "set Infosilem Room ID here"
  @cron_string : String = "*/15 * * * *"
  @todays_upcoming_events : Array(Event) = [] of Event
  @minutes_til_next_event_starts : Int32 | Nil = nil
  @debug : Bool = false

  def on_load
    on_update
  end

  def on_update
    schedule.clear
    @debug = setting(Bool, :debug) || false
    @room_id = setting(String, :infosilem_room_id)
    @cron_string = setting(String, :polling_cron)
    schedule.cron(@cron_string) { fetch_and_expose_todays_events }
  end

  def fetch_and_expose_todays_events
    today = Time.local.to_s("%Y-%m-%d")
    todays_events = Array(Event).from_json(fetch_events(today, today))
    #todays_events = fetch_events(today, today).map { |e| Event.from_json(e) }
    @todays_upcoming_events = todays_events.select { |e| e.startTime > Time.local }
    self[:todays_upcoming_events] = @todays_upcoming_events

    return [] of Event if @todays_upcoming_events.empty?

    next_event = @todays_upcoming_events.min_by { |e| e.startTime }
    update_event_details(next_event)
    schedule.clear
    schedule.cron(@cron_string) { fetch_and_expose_todays_events.as(Array(Event)) }
    schedule.every(1.minutes) { update_event_countdown(next_event) }
    update_event_countdown(next_event)
    return todays_events
  end

  def fetch_events(startDate : String, endDate : String)
    events = infosilem.bookings?(@room_id, startDate, endDate).get.to_s
    logger.debug { "Infosilem Campus returned: #{events}" } if @debug
    events
  end

  private def update_event_countdown(next_event : Event)
    time_til_next_event = next_event.not_nil!.startTime - Time.local
    self[:minutes_til_next_event_starts] = @minutes_til_next_event_starts = time_til_next_event.total_minutes.to_i
    fetch_and_expose_todays_events if next_event.not_nil!.startTime < Time.local
  end

  private def update_event_details(next_event : Event)
    self[:next_event_starts_at] = next_event.startTime
    self[:next_event_id] = next_event.id
    self[:next_event_description] = next_event.description
  end
end
