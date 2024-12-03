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
        todays_events = fetch_events(today.to_s("%Y-%m-%d"), today.to_s("%Y-%m-%d"), today.to_s("%Y%m%d"))

        # Determine which events contain other events
        todays_events.sort_by(&.date.duration).reverse!

        todays_events.each_with_index do |e, i|
          if todays_events.skip(i + 1).find { |f| contains?(e, f) }
            e.container = true
          else
            e.container = false
          end
        end

        current_and_past_events, future_events = todays_events.partition { |e| Time.local > e.date.start_date }
        current_events, past_events = current_and_past_events.partition { |e| in_progress?(e) }

        if @debug
          self[:todays_upcoming_events] = future_events
          self[:todays_past_events] = past_events
        end

        next_event = future_events.min_by? &.date.start_date
        previous_event = past_events.max_by? &.date.end_date
        current_event = current_events.find { |e| !e.container }
        current_container_event = current_events.find(&.container)

        update_event_details(previous_event, current_event, next_event)
        advance_countdowns(previous_event, current_event, next_event, current_container_event)
        todays_events
      ensure
        @request_running = false
      end
    end
  end

  def fetch_events(start_date : String, end_date : String, since : String)
    relevant_events = [] of Models::Event
    events = Array(Models::Event).from_json(twenty_five_live_pro.list_events(1, 100, since, nil).get.not_nil!.to_json)

    events.each do |event|
      details = Models::EventDetail.from_json(twenty_five_live_pro.get_event_details(event.id, ["all"], ["all"]).get.not_nil!.to_json)

      if expanded_info = details.content.expanded_info
        if spaces = expanded_info.spaces
          next if spaces.empty?

          if @space_id == spaces.first.space_id
            if event_data = details.content.data
              if event_items = event_data.items
                next if event_items.empty?

                event_items.each do |event_item|
                  if date = event_item.date
                    if date.start_date.to_rfc3339.includes?(start_date) && date.end_date.to_rfc3339.includes?(start_date)
                      relevant_events.push(Models::Event.from_json(event_item.to_json))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    relevant_events
  end

  private def update_event_details(previous_event : Models::Event | Nil = nil, current_event : Models::Event | Nil = nil, next_event : Models::Event | Nil = nil)
    if previous_event
      self[:previous_event_ends_at] = previous_event.date.end_date
      self[:previous_event_was_container] = previous_event.container
      self[:previous_event_id] = previous_event.id if @debug
    end

    if current_event
      self[:current_event_starts_at] = current_event.date.start_date
      self[:current_event_ends_at] = current_event.date.end_date
      self[:current_event_id] = current_event.id if @debug
      self[:current_event_description] = current_event.name if @debug
    end

    if next_event
      self[:next_event_starts_at] = next_event.date.start_date
      self[:next_event_is_container] = next_event.container
      self[:next_event_id] = next_event.id if @debug
    end
  end

  private def advance_countdowns(previous : Models::Event | Nil, current : Models::Event | Nil, next_event : Models::Event | Nil, container : Models::Event | Nil)
    previous ? countup_previous_event(previous) : (self[:minutes_since_previous_event] = nil)
    next_event_started = next_event ? countdown_next_event(next_event) : (self[:minutes_til_next_event] = nil)
    current_event_ended = current ? countdown_current_event(current) : (self[:minutes_since_current_event_started] = self[:minutes_til_current_event_ends] = nil)

    logger.debug { "Next event started? #{next_event_started}\nCurrent event ended? #{current_event_ended}" } if @debug
    @next_countdown = if next_event_started || current_event_ended
                        schedule.in(1.minutes) { fetch_and_expose_todays_events.as(Array(Models::Event)) }
                      else
                        schedule.in(1.minutes) { advance_countdowns(previous, current, next_event, container).as(Bool) }
                      end

    self[:event_in_progress] = current ? in_progress?(current) : false
    self[:container_event_in_progess] = container ? in_progress?(container) : false
    self[:no_upcoming_events] = next_event.nil?
  end

  private def countup_previous_event(previous : Models::Event)
    time_since_previous = Time.local - previous.date.end_date
    self[:minutes_since_previous_event] = time_since_previous.total_minutes.to_i
  end

  private def countdown_next_event(next_event : Models::Event)
    time_til_next = next_event.date.start_date - Time.local
    self[:minutes_til_next_event] = time_til_next.total_minutes.to_i
    # return whether the next event has started
    Time.local >= next_event.date.start_date
  end

  private def countdown_current_event(current : Models::Event)
    time_since_start = Time.local - current.date.start_date
    time_til_end = current.date.end_date - Time.local
    self[:minutes_since_current_event_started] = time_since_start.total_minutes.to_i
    self[:minutes_til_current_event_ends] = time_til_end.total_minutes.to_i
    # return whether the current event has ended
    Time.local > current.date.end_date
  end

  private def in_progress?(event : Models::Event)
    now = Time.local
    now >= event.date.start_date && now <= event.date.end_date
  end

  # Does a contain b?
  private def contains?(a : Models::Event, b : Models::Event)
    b.date.start_date >= a.date.start_date && b.date.end_date <= a.date.end_date
  end

  private def overlaps?(a : Models::Event, b : Models::Event)
    b.date.start_date < a.date.end_date || b.date.end_date > a.date.start_date
  end
end
