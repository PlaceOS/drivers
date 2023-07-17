require "placeos-driver"
require "./models/**"

class TwentyFiveLivePro::RoomSchedule < PlaceOS::Driver
  descriptive_name "25Live Pro Room Schedule Logic"
  generic_name :RoomSchedule
  description %(Polls 25Live Pro API Module to expose bookings relevant for the selected System)

  default_settings({
    twenty_five_live_pro_space_id: "set 25Live Pro Space ID here",
    polling_cron:                  "*/15 * * * *",
    debug:                         false,
  })

  accessor twenty_five_live_pro : API_1

  @space_id : String = "set 25Live Pro Space ID here"
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
    @space_id = setting(String, :twenty_five_live_pro_space_id)
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
        today = Time.local
        todays_events = fetch_events(today.to_s("%Y-%m-%d"), today.to_s("%Y-%m-%d"))

        # Determine which events contain other events
        # todays_events.sort_by(&.duration).reverse!

        # todays_events.each_with_index do |e, i|
        # if todays_events.skip(i + 1).find { |f| contains?(e, f) }
        # e.container = true
        # else
        # e.container = false
        # end
        # end

        current_and_past_events, future_events = todays_events.partition { |e| Time.local > Time.parse_rfc3339 e.reservation_start_dt }
        current_events, past_events = current_and_past_events.partition { |e| in_progress?(e) }

        if @debug
          self[:todays_upcoming_events] = future_events
          self[:todays_past_events] = past_events
        end

        next_event = future_events.min_by? &.reservation_start_dt
        previous_event = past_events.max_by? &.reservation_end_dt
        current_event = current_events.find { |e| }
        #current_container_event = current_events.find(&.container)

        update_event_details(previous_event, current_event, next_event)
        advance_countdowns(previous_event, current_event, next_event)
        todays_events
      ensure
        @request_running = false
      end
    end
  end

  def fetch_events(start_date : String, end_date : String)
    relevant_reservations = [] of Models::Reservation
    reservations = Array(Models::Reservation).from_json(twenty_five_live_pro.list_reservations(88, start_date, end_date).get.not_nil!.to_json)

    reservations.each do |reservation|
      start_date = Time.parse_rfc3339 reservation.reservation_start_dt
      end_date = Time.parse_rfc3339 reservation.reservation_end_dt
    end

    relevant_reservations
  end

  private def update_event_details(previous_event : Models::Reservation | Nil = nil, current_event : Models::Reservation | Nil = nil, next_event : Models::Reservation | Nil = nil)
    if previous_event
      self[:previous_event_ends_at] = previous_event.reservation_end_dt
      self[:previous_event_id] = previous_event.reservation_id if @debug
    end

    if current_event
      self[:current_event_starts_at] = current_event.reservation_start_dt
      self[:current_event_ends_at] = current_event.reservation_end_dt
      self[:current_event_id] = current_event.reservation_id if @debug
      self[:current_event_description] = current_event.event_title if @debug
    end

    if next_event
      self[:next_event_starts_at] = next_event.reservation_start_dt
      self[:next_event_id] = next_event.reservation_id if @debug
    end
  end

  private def advance_countdowns(previous : Models::Reservation | Nil, current : Models::Reservation | Nil, next_event : Models::Reservation | Nil)
    previous ? countup_previous_event(previous) : (self[:minutes_since_previous_event] = nil)
    next_event_started = next_event ? countdown_next_event(next_event) : (self[:minutes_til_next_event] = nil)
    current_event_ended = current ? countdown_current_event(current) : (self[:minutes_since_current_event_started] = self[:minutes_til_current_event_ends] = nil)

    logger.debug { "Next event started? #{next_event_started}\nCurrent event ended? #{current_event_ended}" } if @debug
    @next_countdown = if next_event_started || current_event_ended
                        schedule.in(1.minutes) { fetch_and_expose_todays_events.as(Array(Models::Reservation)) }
                      else
                        schedule.in(1.minutes) { advance_countdowns(previous, current, next_event).as(Bool) }
                      end

    self[:event_in_progress] = current ? in_progress?(current) : false
    self[:no_upcoming_events] = next_event.nil?
  end

  private def countup_previous_event(previous : Models::Reservation)
    time_since_previous = Time.local - Time.parse_rfc3339 previous.reservation_end_dt
    self[:minutes_since_previous_event] = time_since_previous.total_minutes.to_i
  end

  private def countdown_next_event(next_event : Models::Reservation)
    time_til_next = Time.parse_rfc3339(next_event.reservation_start_dt) - Time.local
    self[:minutes_til_next_event] = time_til_next.total_minutes.to_i
    # return whether the next event has started
    Time.local >= Time.parse_rfc3339 next_event.reservation_start_dt
  end

  private def countdown_current_event(current : Models::Reservation)
    time_since_start = Time.local - Time.parse_rfc3339 current.reservation_start_dt
    time_til_end = Time.parse_rfc3339(current.reservation_end_dt) - Time.local
    self[:minutes_since_current_event_started] = time_since_start.total_minutes.to_i
    self[:minutes_til_current_event_ends] = time_til_end.total_minutes.to_i
    # return whether the current event has ended
    Time.local > Time.parse_rfc3339 current.reservation_end_dt
  end

  private def in_progress?(reservation : Models::Reservation)
    now = Time.local
    now >= Time.parse_rfc3339(reservation.reservation_start_dt) && now <= Time.parse_rfc3339(reservation.reservation_end_dt)
  end

  # Does a contain b?
  private def contains?(a : Models::Reservation, b : Models::Reservation)
    breservation_start_dt >= areservation_start_dt && breservation_end_dt <= areservation_end_dt
  end

  private def overlaps?(a : Models::Reservation, b : Models::Reservation)
    breservation_start_dt < areservation_end_dt || breservation_end_dt > areservation_start_dt
  end
end
