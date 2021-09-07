require "placeos-driver"
require "place_calendar"
require "placeos-driver/interface/locatable"
require "placeos-driver/interface/sensor"

class Place::Bookings < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "PlaceOS Bookings"
  generic_name :Bookings

  default_settings({
    calendar_id:            nil,
    calendar_time_zone:     "Australia/Sydney",
    book_now_default_title: "Ad Hoc booking",
    disable_book_now:       false,
    disable_end_meeting:    false,
    pending_period:         5,
    pending_before:         5,
    cache_polling_period:   5,
    cache_days:             30,

    # as graph API is eventually consistent we want to delay syncing for a moment
    change_event_sync_delay: 5,

    control_ui:  "https://if.panel/to_be_used_for_control",
    catering_ui: "https://if.panel/to_be_used_for_catering",

    include_cancelled_bookings: false,
  })

  accessor calendar : Calendar_1

  @calendar_id : String = ""
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @default_title : String = "Ad Hoc booking"
  @disable_book_now : Bool = false
  @disable_end_meeting : Bool = false
  @pending_period : Time::Span = 5.minutes
  @pending_before : Time::Span = 5.minutes
  @bookings : Array(JSON::Any) = [] of JSON::Any
  @change_event_sync_delay : UInt32 = 5_u32
  @cache_days : Time::Span = 30.days
  @include_cancelled_bookings : Bool = false

  @perform_sensor_search : Bool = true

  def on_load
    monitor("staff/event/changed") { |_subscription, payload| check_change(payload) }

    on_update
  end

  def on_update
    schedule.clear
    @calendar_id = setting?(String, :calendar_id).presence || system.email.not_nil!

    @perform_sensor_search = true
    schedule.in(Random.rand(60).seconds + Random.rand(1000).milliseconds) { poll_events }

    cache_polling_period = (setting?(UInt32, :cache_polling_period) || 2_u32).minutes
    cache_polling_period += Random.rand(30).seconds + Random.rand(1000).milliseconds
    schedule.every(cache_polling_period) { poll_events }

    time_zone = setting?(String, :calendar_time_zone).presence || config.control_system.not_nil!.timezone.presence
    @time_zone = Time::Location.load(time_zone) if time_zone

    @default_title = setting?(String, :book_now_default_title).presence || "Ad Hoc booking"

    book_now = setting?(Bool, :disable_book_now)
    @disable_book_now = book_now.nil? ? !system.bookable : !!book_now
    @disable_end_meeting = !!setting?(Bool, :disable_end_meeting)

    pending_period = setting?(UInt32, :pending_period) || 5_u32
    @pending_period = pending_period.minutes

    pending_before = setting?(UInt32, :pending_before) || 5_u32
    @pending_before = pending_before.minutes

    cache_days = setting?(UInt32, :cache_days) || 30_u32
    @cache_days = cache_days.days

    @change_event_sync_delay = setting?(UInt32, :change_event_sync_delay) || 5_u32

    @last_booking_started = setting?(Int64, :last_booking_started) || 0_i64

    @include_cancelled_bookings = setting?(Bool, :include_cancelled_bookings) || false

    # Write to redis last on the off chance there is a connection issue
    self[:default_title] = @default_title
    self[:disable_book_now] = @disable_book_now
    self[:disable_end_meeting] = @disable_end_meeting
    self[:pending_period] = pending_period
    self[:pending_before] = pending_before
    self[:control_ui] = setting?(String, :control_ui)
    self[:catering_ui] = setting?(String, :catering_ui)
  end

  # This is how we check the rooms status
  @last_booking_started : Int64 = 0_i64

  def start_meeting(meeting_start_time : Int64) : Nil
    logger.debug { "starting meeting #{meeting_start_time}" }
    @last_booking_started = meeting_start_time
    define_setting(:last_booking_started, meeting_start_time)
    check_current_booking
  end

  # End either the current meeting early, or the pending meeting
  def end_meeting(meeting_start_time : Int64) : Nil
    cmeeting = current
    result = if cmeeting && cmeeting.event_start.to_unix == meeting_start_time
               logger.debug { "deleting event #{cmeeting.title}, from #{@calendar_id}" }
               calendar.delete_event(@calendar_id, cmeeting.id)
             else
               nmeeting = upcoming
               if nmeeting && nmeeting.event_start.to_unix == meeting_start_time
                 logger.debug { "deleting event #{nmeeting.title}, from #{@calendar_id}" }
                 calendar.delete_event(@calendar_id, nmeeting.id)
               else
                 raise "only the current or pending meeting can be cancelled"
               end
             end
    result.get

    # Update the display
    poll_events
    check_current_booking
  end

  def book_now(period_in_seconds : Int64, title : String? = nil, owner : String? = nil)
    title ||= @default_title
    starting = Time.utc.to_unix
    ending = starting + period_in_seconds

    logger.debug { "booking event #{title}, from #{starting}, to #{ending}, in #{@time_zone.name}, on #{@calendar_id}" }

    host_calendar = owner.presence || @calendar_id
    room_email = system.email.not_nil!
    room_is_organizer = host_calendar == room_email
    event = calendar.create_event(
      title,
      starting,
      ending,
      "",
      [PlaceCalendar::Event::Attendee.new(room_email, room_email, "accepted", true, room_is_organizer)],
      @time_zone.name,
      nil,
      host_calendar
    )
    # Update booking info after creating event
    poll_events
    event
  end

  def poll_events : Nil
    check_for_sensors if @perform_sensor_search

    now = Time.local @time_zone
    start_of_week = now.at_beginning_of_week.to_unix
    four_weeks_time = start_of_week + @cache_days.to_i

    logger.debug { "polling events #{@calendar_id}, from #{start_of_week}, to #{four_weeks_time}, in #{@time_zone.name}" }

    events = calendar.list_events(
      @calendar_id,
      start_of_week,
      four_weeks_time,
      @time_zone.name,
      include_cancelled: @include_cancelled_bookings
    ).get

    @bookings = events.as_a.sort { |a, b| a["event_start"].as_i64 <=> b["event_start"].as_i64 }
    self[:bookings] = @bookings

    check_current_booking
  end

  protected def check_current_booking : Nil
    now = Time.utc.to_unix
    previous_booking = nil
    current_booking = nil
    next_booking = Int32::MAX

    @bookings.each_with_index do |event, index|
      starting = event["event_start"].as_i64

      # All meetings are in the future
      if starting > now
        next_booking = index
        previous_booking = index - 1 if index > 0
        break
      end

      # Calculate event end time
      ending_unix = if ending = event["event_end"]?
                      ending.as_i64
                    else
                      starting + 24.hours.to_i
                    end

      # Event ended in the past
      next if ending_unix < now

      # We've found the current event
      if starting <= now && ending_unix > now
        current_booking = index
        previous_booking = index - 1 if index > 0
        next_booking = index + 1
        break
      end
    end

    self[:previous_booking] = previous_booking ? @bookings[previous_booking] : nil

    # Configure room status (free, pending, in-use)
    current_pending = false
    next_pending = false
    booked = false

    if current_booking
      booking = @bookings[current_booking]
      start_time = booking["event_start"].as_i64

      booked = true
      # Up to the frontend to delete pending bookings that have past their start time
      if !@disable_end_meeting
        current_pending = true if start_time > @last_booking_started
      elsif @pending_period.to_i > 0_i64
        pending_limit = (Time.unix(start_time) + @pending_period).to_unix
        current_pending = true if start_time < pending_limit
      end

      self[:current_booking] = booking
    else
      self[:current_booking] = nil
    end

    self[:booked] = booked

    # We haven't checked the index of `next_booking` exists, hence the `[]?`
    if booking = @bookings[next_booking]?
      start_time = booking["event_start"].as_i64
      next_pending = true if start_time <= @pending_before.from_now.to_unix
      self[:next_booking] = booking
    else
      self[:next_booking] = nil
    end

    # Check if pending is enabled
    if @pending_period.to_i > 0_i64
      self[:current_pending] = current_pending
      self[:next_pending] = next_pending
      self[:pending] = current_pending || next_pending

      self[:in_use] = booked && !current_pending
    else
      self[:current_pending] = false
      self[:next_pending] = false
      self[:pending] = false

      self[:in_use] = booked
    end

    # TODO:: set video_conference_url if found in the event details

    self[:status] = (current_pending || next_pending) ? "pending" : (booked ? "busy" : "free")
  end

  protected def current : PlaceCalendar::Event?
    status?(PlaceCalendar::Event, :current_booking)
  end

  protected def upcoming : PlaceCalendar::Event?
    status?(PlaceCalendar::Event, :next_booking)
  end

  protected def pending : PlaceCalendar::Event?
    status?(PlaceCalendar::Event, :next_booking)
  end

  class StaffEventChange
    include JSON::Serializable

    property action : String    # create, update, cancelled
    property system_id : String # primary calendar effected
    property event_id : String
    property resource : String # the resource email that is effected
  end

  # This is called when bookings are modified via the staff app
  # it allows us to update the cache faster than via polling alone
  protected def check_change(payload : String)
    event = StaffEventChange.from_json(payload)
    if event.system_id == system.id
      sleep @change_event_sync_delay
      poll_events
      check_current_booking
    else
      matching = @bookings.select { |b| b["id"] == event.event_id }
      if matching
        sleep @change_event_sync_delay
        poll_events
        check_current_booking
      end
    end
  rescue error
    logger.error { "processing change event: #{error.inspect_with_backtrace}" }
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  protected def to_location_format(events : Enumerable(PlaceCalendar::Event))
    sys = system.config
    events.map do |event|
      event_ends = event.all_day? ? event.event_start.in(@time_zone).at_end_of_day : event.event_end.not_nil!
      {
        location: :meeting,
        mac:      @calendar_id,
        event_id: event.id,
        map_id:   sys.map_id,
        sys_id:   sys.id,
        ends_at:  event_ends.to_unix,
        private:  !!event.private?,
      }
    end
  end

  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }

    email = email.to_s.downcase
    username = username.to_s.downcase
    matching_events = [] of PlaceCalendar::Event

    if event = current
      emails = event.attendees.map(&.email.downcase)
      if host = event.host
        emails << host.downcase
      end

      if emails.includes?(email) || emails.includes?(username)
        logger.debug { "found user {#{email}, #{username}} in list of attendees" }
        matching_events << event
      elsif !username.empty? && emails.find(&.starts_with?(username))
        logger.debug { "found email starting with username '#{username}' in list of attendees" }
        matching_events << event
      end
    end

    to_location_format matching_events
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    locate_user(email, username).map(&.[](:mac))
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "searching for owner of #{mac_address}" }
    sys_email = @calendar_id.downcase
    if sys_email == mac_address.downcase && (host = current.try &.host)
      {
        location:    "meeting",
        assigned_to: host,
        mac_address: sys_email,
      }
    end
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    [] of Nil
  end

  protected def check_for_sensors
    drivers = system.implementing(Interface::Sensor)

    subscriptions.clear

    # Prefer people count data in a space
    count_data = drivers.sensors("people_count").get.flat_map(&.as_a).first?
    if count_data && count_data["module_id"]?.try(&.raw.is_a?(String))
      self[:sensor_name] = count_data["name"].as_s
      subscriptions.subscribe(count_data["module_id"].as_s, count_data["binding"].as_s) do |_sub, payload|
        value = (Float64 | Nil).from_json payload
        if value
          self[:people_count] = value
          self[:presence] = value > 0.0
        else
          self[:people_count] = self[:presence] = nil
        end
      end
    else
      self[:people_count] = nil

      # Fallback to checking for presence
      presence = drivers.sensors("presence").get.flat_map(&.as_a).first?
      if presence && presence["module_id"]?.try(&.raw.is_a?(String))
        self[:sensor_name] = presence["name"].as_s
        subscriptions.subscribe(presence["module_id"].as_s, presence["binding"].as_s) do |_sub, payload|
          value = (Float64 | Nil).from_json payload
          self[:presence] = value ? value > 0.0 : nil
        end
      else
        self[:sensor_name] = self[:presence] = nil
      end
    end

    @perform_sensor_search = false
  rescue error
    self[:people_count] = nil
    self[:presence] = nil
    self[:sensor_name] = nil
    logger.error(exception: error) { "checking for sensors" }
  end
end
