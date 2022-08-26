require "placeos-driver"
require "./models"

class Infosilem::RoomSchedule < PlaceOS::Driver
  descriptive_name "Infosilem Room Schedule Logic"
  generic_name :RoomSchedule
  description %(Polls Infosilem Campus Module to expose bookings relevant for the selected System)

  default_settings({
    infosilem_room_id: "set Infosilem Room ID here",
    polling_cron:      "*/15 * * * *",
    debug:             false,
  })

  accessor infosilem : Campus_1

  @room_id : String = "set Infosilem Room ID here"
  @cron_string : String = "*/15 * * * *"
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
    fetch_and_expose_todays_events
  end

  def fetch_and_expose_todays_events
    today = Time.local.to_s("%Y-%m-%d")
    todays_events = Array(Event).from_json(fetch_events(today, today))
    past_events, future_events = todays_events.partition { |e| Time.local > e.startTime }
    self[:todays_upcoming_events] = future_events

    next_event      = future_events.min_by? &.startTime
    previous_event  = past_events.max_by? &.endTime
    current_event   = past_events.find { |e| in_progress?(e)}
    update_event_details(previous_event, current_event, next_event)

    schedule.clear
    schedule.cron(@cron_string) { fetch_and_expose_todays_events.as(Array(Event)) }
    schedule.every(1.minutes) { advance_countdowns(previous_event, current_event, next_event) }
    advance_countdowns(previous_event, current_event, next_event)
    
    return todays_events
  end

  def fetch_events(startDate : String, endDate : String)
    events = infosilem.bookings?(@room_id, startDate, endDate).get.to_s
    logger.debug { "Infosilem Campus returned: #{events}" } if @debug
    events
  end

  private def update_event_details(previous_event : Event | Nil = nil, current_event : Event | Nil = nil, next_event : Event | Nil = nil)
    self[:previous_event_ends_at]   = previous_event.try &.endTime
    self[:previous_event_id]        = previous_event.try &.id if @debug

    self[:current_event_starts_at]  = current_event.try &.startTime
    self[:current_event_end_at]     = current_event.try &.endTime
    self[:current_event_id]         = current_event.try &.id if @debug

    self[:next_event_starts_at]     = next_event.try &.startTime
    self[:next_event_id]            = next_event.try &.id if @debug
  end

  private def advance_countdowns(previous : Event | Nil, current : Event | Nil, next_event  : Event | Nil )
    previous ? countup_previous_event(previous) : {self[:minutes_since_previous_event] = nil}
    next_event ? countdown_next_event(next_event) : {self[:minutes_til_next_event] = nil}
    current ? countdown_current_event(current) : {self[:minutes_since_current_event_started] = self[:minutes_til_current_event_ends] = nil}
  end

  private def countup_previous_event(previous : Event)
    time_since_previous = Time.local - previous.endTime
    self[:minutes_since_previous_event] = time_since_previous.total_minutes.to_i
  end

  private def countdown_next_event(next_event : Event)
    time_til_next = next_event.startTime - Time.local
    self[:minutes_til_next_event] = time_til_next.total_minutes.to_i
    fetch_and_expose_todays_events if Time.local > next_event.startTime 
  end

  private def countdown_current_event(current : Event)
    time_since_start = Time.local - current.startTime
    time_til_end = current.endTime - Time.local
    self[:minutes_since_current_event_started] = time_since_start.total_minutes.to_i
    self[:minutes_til_current_event_ends]      = time_til_end.total_minutes.to_i
    fetch_and_expose_todays_events if Time.local > current.endTime 
  end

  private def in_progress?(event : Event)
    now = Time.local
    now >= event.startTime && now <= event.endTime
  end
end
