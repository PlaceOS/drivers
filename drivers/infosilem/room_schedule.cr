require "placeos-driver"
require "./models"

class Infosilem::RoomSchedule < PlaceOS::Driver
  descriptive_name "Infosilem Room Schedule Logic"
  generic_name :RoomSchedule
  description %(Polls Infosilem Campus Module to expose bookings relevant for the selected System)

  default_settings({
    infosilem_room_id:       "set Infosilem Room ID here",
    polling_cron:            "*/15 * * * *",
    ignore_container_events: true,
    debug:                   false,
  })

  accessor infosilem : Campus_1

  @building_id : String = "set Infosilem Building ID here"
  @room_id : String = "set Infosilem Room ID here"
  @cron_string : String = "*/15 * * * *"
  @debug : Bool = false
  @next_countdown : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
  @request_lock : Mutex = Mutex.new
  @request_running : Bool = false

  def on_load
    on_update
  end

  def on_update
    @debug = setting(Bool, :debug) || false
    @ignore_container_events = setting(Bool, :ignore_container_events) || true
    @building_id = setting(String, :infosilem_building_id)
    @room_id = setting(String, :infosilem_room_id)
    @cron_string = setting(String, :polling_cron)
    schedule.clear
    schedule.cron(@cron_string, immediate: true) { fetch_and_expose_todays_events }
  end

  def fetch_and_expose_todays_events
    return if @request_running

    @request_lock.synchronize do
      begin
        @request_running = true
        @next_countdown.try &.cancel
        @next_countdown = nil
        today = Time.local.to_s("%Y-%m-%d")
        todays_events = Array(Event).from_json(fetch_events(today, today))

        if @ignore_container_events
          # Determine which events contain other events
          container_events = [] of Event
          todays_events.sort_by(&.duration).reverse!
          todays_events.each_with_index do |e, i|
            if todays_events.skip(i + 1).find { |f| contains?(e, f) }
              container_events << e
            end
          end
          todays_events = todays_events - container_events
        end

        current_and_past_events, future_events = todays_events.partition { |e| Time.local > e.start_time }
        current_events, past_events = current_and_past_events.partition { |e| in_progress?(e) }

        if @debug
          self[:todays_upcoming_events] = future_events
          self[:todays_past_events] = past_events
          self[:ignored_events] = container_events
        end

        next_event = future_events.min_by? &.start_time
        current_event = current_events.first?
        previous_event = past_events.max_by? &.end_time

        update_event_details(previous_event, current_event, next_event)
        advance_countdowns(previous_event, current_event, next_event)
        todays_events
      ensure
        @request_running = false
      end
    end
  end

  def fetch_events(start_date : String, end_date : String)
    events = infosilem.bookings?(@building_id, @room_id, start_date, end_date).get.to_json
    logger.debug { "Infosilem Campus returned: #{events}" } if @debug
    events
  end

  private def update_event_details(previous_event : Event | Nil = nil, current_event : Event | Nil = nil, next_event : Event | Nil = nil)
    self[:previous_event_ends_at] = previous_event.try &.end_time
    self[:previous_event_id] = previous_event.try &.id if @debug

    self[:current_event_starts_at] = current_event.try &.start_time
    self[:current_event_ends_at] = current_event.try &.end_time
    self[:current_event_attendees] = current_event.try &.number_of_attendees
    self[:current_event_conflicting] = current_event.try &.conflicting
    self[:current_event_id] = current_event.try &.id if @debug
    self[:current_event_description] = current_event.try &.description if @debug

    self[:next_event_starts_at] = next_event.try &.start_time
    self[:next_event_id] = next_event.try &.id if @debug
  end

  private def advance_countdowns(previous : Event | Nil, current : Event | Nil, next_event : Event | Nil)
    previous ? countup_previous_event(previous) : (self[:minutes_since_previous_event] = nil)
    next_event_started = next_event ? countdown_next_event(next_event) : (self[:minutes_til_next_event] = nil)
    current_event_ended = current ? countdown_current_event(current) : (self[:minutes_since_current_event_started] = self[:minutes_til_current_event_ends] = nil)

    logger.debug { "Next event started? #{next_event_started}\nCurrent event ended? #{current_event_ended}" } if @debug
    @next_countdown = if next_event_started || current_event_ended
                        schedule.in(1.minutes) { fetch_and_expose_todays_events.as(Array(Event)) }
                      else
                        schedule.in(1.minutes) { advance_countdowns(previous, current, next_event).as(Bool) }
                      end

    self[:event_in_progress] = current ? in_progress?(current) : false
    self[:no_upcoming_events] = next_event.nil?
  end

  private def countup_previous_event(previous : Event)
    time_since_previous = Time.local - previous.end_time
    self[:minutes_since_previous_event] = time_since_previous.total_minutes.to_i
  end

  private def countdown_next_event(next_event : Event)
    time_til_next = next_event.start_time - Time.local
    self[:minutes_til_next_event] = time_til_next.total_minutes.to_i
    # return whether the next event has started
    Time.local >= next_event.start_time
  end

  private def countdown_current_event(current : Event)
    time_since_start = Time.local - current.start_time
    time_til_end = current.end_time - Time.local
    self[:minutes_since_current_event_started] = time_since_start.total_minutes.to_i
    self[:minutes_til_current_event_ends] = time_til_end.total_minutes.to_i
    # return whether the current event has ended
    Time.local > current.end_time
  end

  private def in_progress?(event : Event)
    now = Time.local
    now >= event.start_time && now <= event.end_time
  end

  # Does a contain b?
  private def contains?(a : Event, b : Event)
    b.start_time >= a.start_time && b.end_time <= a.end_time
  end

  private def overlaps?(a : Event, b : Event)
    b.start_time < a.end_time || b.end_time > a.start_time
  end
end
