require "placeos-driver"
require "place_calendar"
require "placeos-driver/interface/locatable"
require "placeos-driver/interface/sensor"

class Place::Bookings < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "PlaceOS Room Events"
  generic_name :Bookings

  default_settings({
    calendar_id:            nil,
    calendar_time_zone:     "Australia/Sydney",
    book_now_default_title: "Ad Hoc booking",
    disable_book_now_host:  false,
    disable_book_now:       false,
    disable_end_meeting:    false,
    pending_period:         5,
    pending_before:         5,
    cache_polling_period:   5,
    cache_days:             30,

    # consider sensor data older than this unreliable
    sensor_stale_minutes: 8,

    # as graph API is eventually consistent we want to delay syncing for a moment
    change_event_sync_delay: 5,

    control_ui:  "https://if.panel/to_be_used_for_control",
    catering_ui: "https://if.panel/to_be_used_for_catering",

    application_permissions:    true,
    include_cancelled_bookings: false,
    hide_qr_code:               false,
    custom_qr_url:              "https://domain.com/path",
    custom_qr_color:            "black",

    # This image is displayed along with the capacity when the room is not bookable
    room_image: "https://domain.com/room_image.svg",
    sensor_mac: "device-mac",

    hide_meeting_details:      false,
    hide_meeting_title:        false,
    enable_end_meeting_button: false,
    max_user_search_results:   20,

    # use this to expose arbitrary fields to influx
    # expose_for_analytics: {"binding" => "key->subkey"},

    # use these for enabling push notifications
    # push_authority: "authority-GAdySsf05mL"
    # push_notification_url: "https://placeos-dev.aca.im/api/engine/v2/notifications/office365"
    # push_notification_url: "https://placeos-dev.aca.im/api/engine/v2/notifications/google"
  })

  accessor calendar : Calendar_1

  getter calendar_id : String = ""
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @default_title : String = "Ad Hoc booking"
  @disable_book_now : Bool = false
  @disable_end_meeting : Bool = false
  @pending_period : Time::Span = 5.minutes
  @pending_before : Time::Span = 5.minutes
  @change_event_sync_delay : UInt32 = 5_u32
  @cache_days : Time::Span = 30.days
  @include_cancelled_bookings : Bool = false
  @application_permissions : Bool = false
  @disable_book_now_host : Bool = false
  @max_user_search_results : UInt32 = 20

  @current_meeting_id : String = ""
  @current_pending : Bool = false
  @next_pending : Bool = false
  @expose_for_analytics : Hash(String, String) = {} of String => String

  @sensor_stale_minutes : Time::Span = 8.minutes
  @perform_sensor_search : Bool = true
  @sensor_mac : String? = nil

  def on_load
    on_update
  end

  def on_update
    schedule.clear
    @calendar_id = (setting?(String, :calendar_id).presence || system.email.not_nil!).downcase

    @perform_sensor_search = true
    schedule.in(Random.rand(30).seconds + Random.rand(30_000).milliseconds) { poll_events }

    cache_polling_period = (setting?(UInt32, :cache_polling_period) || 2_u32).minutes.total_milliseconds.to_i
    cache_polling_period += Random.rand(5_000)
    cache_random_period = cache_polling_period // 3
    schedule.every(cache_polling_period.milliseconds) do
      schedule.in(Random.rand(cache_random_period).milliseconds) { poll_events }
    end

    time_zone = setting?(String, :calendar_time_zone).presence || config.control_system.not_nil!.timezone.presence
    @time_zone = Time::Location.load(time_zone) if time_zone

    @default_title = setting?(String, :book_now_default_title).presence || "Ad Hoc booking"

    book_now = setting?(Bool, :disable_book_now)
    not_bookable = setting?(Bool, :not_bookable) || false
    self[:bookable] = bookable = not_bookable ? false : system.bookable
    @disable_book_now = book_now.nil? ? !bookable : !!book_now
    @disable_end_meeting = !!setting?(Bool, :disable_end_meeting)
    @disable_book_now_host = setting?(Bool, :disable_book_now_host) || false
    @max_user_search_results = setting?(UInt32, :max_user_search_results) || 20_u32

    pending_period = setting?(UInt32, :pending_period) || 5_u32
    @pending_period = pending_period.minutes

    pending_before = setting?(UInt32, :pending_before) || 5_u32
    @pending_before = pending_before.minutes

    cache_days = setting?(UInt32, :cache_days) || 30_u32
    @cache_days = cache_days.days

    @change_event_sync_delay = setting?(UInt32, :change_event_sync_delay) || 5_u32

    # ensure we don't load any millisecond timestamps
    last_started = setting?(Int64, :last_booking_started) || 0_i64
    @last_booking_started = last_started > 30.minutes.from_now.to_unix ? 0_i64 : last_started

    @include_cancelled_bookings = setting?(Bool, :include_cancelled_bookings) || false
    @application_permissions = setting?(Bool, :application_permissions) || false

    @sensor_stale_minutes = (setting?(Int32, :sensor_stale_minutes) || 8).minutes
    @expose_for_analytics = setting?(Hash(String, String), :expose_for_analytics) || {} of String => String

    # ensure current booking is updated at the start of every minute
    # rand spreads the load placed on redis
    schedule.cron("* * * * *") do
      schedule.in(rand(1000).milliseconds) do
        if list = self[:bookings]?
          check_current_booking(list.as_a)
        end
      end
    end

    # configure push notifications
    push_notificaitons_configure

    # Write to redis last on the off chance there is a connection issue
    self[:room_name] = setting?(String, :room_name).presence || config.control_system.not_nil!.display_name.presence || config.control_system.not_nil!.name
    self[:room_capacity] = setting?(Int32, :room_capacity) || config.control_system.not_nil!.capacity
    self[:default_title] = @default_title
    self[:disable_book_now_host] = @disable_book_now_host
    self[:disable_book_now] = @disable_book_now
    self[:disable_end_meeting] = @disable_end_meeting
    self[:pending_period] = pending_period
    self[:pending_before] = pending_before
    self[:control_ui] = setting?(String, :control_ui)
    self[:catering_ui] = setting?(String, :catering_ui)
    self[:room_image] = setting?(String, :room_image)
    self[:hide_meeting_details] = setting?(Bool, :hide_meeting_details) || false
    self[:hide_meeting_title] = setting?(Bool, :hide_meeting_title) || false

    self[:offline_color] = setting?(String, :offline_color)
    self[:offline_image] = setting?(String, :offline_image)

    self[:custom_qr_color] = setting?(String, :custom_qr_color)
    self[:custom_qr_url] = setting?(String, :custom_qr_url)
    self[:show_qr_code] = !(setting?(Bool, :hide_qr_code) || false)

    self[:sensor_mac] = @sensor_mac = setting?(String, :sensor_mac)

    # min and max meeting duration
    self[:min_duration] = setting?(Int32, :min_duration) || 15
    self[:max_duration] = setting?(Int32, :max_duration) || 480

    self[:enable_end_meeting_button] = setting?(Bool, :enable_end_meeting_button) || false
  end

  # This is how we check the rooms status
  @last_booking_started : Int64 = 0_i64

  # we no longer accept user specified values
  def start_meeting(meeting_start_time : Int64) : Nil
    logger.warn { "deprecated function call to start_meeting, please use checkin" }
    checkin
  end

  def checkin : Nil
    if booking = pending || current
      check_in_actual booking.event_start.to_unix
    end
  end

  private def check_in_actual(meeting_start_time : Int64, check_bookings : Bool = true)
    logger.debug { "starting meeting @ #{meeting_start_time}" }
    @last_booking_started = meeting_start_time
    define_setting(:last_booking_started, meeting_start_time)
    self[:last_booking_started] = meeting_start_time
    check_current_booking(self[:bookings].as_a) if check_bookings
  end

  # End either the current meeting early, or the pending meeting
  def end_meeting(meeting_start_time : Int64, notify : Bool = true, comment : String = "cancelled at booking panel") : Nil
 
  end

  # Allow apps to search for attendees (to add to new bookings) via driver instead of via staff-api (as some role based accounts may not have MS Graph access)
  def list_users(query : String? = nil, limit : UInt32? = 20_u32)
    calendar.list_users(query, limit)
  end

  def book_now(period_in_seconds : Int64, title : String? = nil, owner : String? = nil)
    title ||= @default_title
    starting = Time.utc.to_unix
    ending = starting + period_in_seconds

    # is the room about to be used?
    raise "the room is currently in use" if @next_pending || status?(Bool, "in_use")

    # will the next booking overlap with the room?
    if next_booking = upcoming
      raise "unable to book due to clash" if next_booking.event_start.to_unix < ending
    end

    logger.debug { "booking event #{title}, from #{starting}, to #{ending}, in #{@time_zone.name}, on #{@calendar_id}" }

    room_email = system.email.not_nil!

    if @application_permissions
      host_calendar = @calendar_id
      attendees = [PlaceCalendar::Event::Attendee.new(room_email, room_email, "accepted", true, true)]
      attendees << PlaceCalendar::Event::Attendee.new(owner, owner) if owner && !owner.empty?
    else
      host_calendar = owner.presence || @calendar_id
      room_is_organizer = host_calendar == room_email
      attendees = [
        PlaceCalendar::Event::Attendee.new(room_email, room_email, "accepted", true, room_is_organizer),
      ]
    end

    event = calendar.create_event(
      title: title,
      event_start: starting,
      event_end: ending,
      description: "",
      attendees: attendees,
      location: status?(String, "room_name"),
      timezone: @time_zone.name,
      calendar_id: host_calendar
    )
    # Update booking info after creating event
    schedule.in(2.seconds) { poll_events } unless (subscription = @subscription) && !subscription.expired?

    check_in_actual starting, check_bookings: false
    event
  end

  @polling : Bool = false

  def poll_events : Nil
    return if @polling
    @polling = true
    check_for_sensors if @perform_sensor_search

    now = Time.local @time_zone
    start_of_day = now.at_beginning_of_day.to_unix
    cache_period = start_of_day + @cache_days.to_i

    logger.debug { "polling events #{@calendar_id}, from #{start_of_day}, to #{cache_period}, in #{@time_zone.name}" }

    events = calendar.list_events(
      @calendar_id,
      start_of_day,
      cache_period,
      @time_zone.name,
      include_cancelled: @include_cancelled_bookings
    ).get.as_a.sort { |a, b| a["event_start"].as_i64 <=> b["event_start"].as_i64 }

    self[:bookings] = events
    check_current_booking(events)
    events
  ensure
    @polling = false
  end

  protected def check_current_booking(bookings) : Nil
    now = Time.utc.to_unix
    previous_booking = nil
    current_booking = nil
    next_booking = Int32::MAX

    bookings.each_with_index do |event, index|
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

    self[:previous_booking] = previous_booking ? bookings[previous_booking] : nil

    # Configure room status (free, pending, in-use)
    current_pending = false
    next_pending = false
    booked = false

    if current_booking
      booking = bookings[current_booking]
      start_time = booking["event_start"].as_i64
      ending_at = booking["event_end"]?
      booked = true

      # Up to the frontend to delete pending bookings that have past their start time
      if !@disable_end_meeting
        current_pending = true if start_time > @last_booking_started
      elsif @pending_period.to_i > 0_i64
        pending_limit = (Time.unix(start_time) + @pending_period).to_unix
        current_pending = true if start_time < pending_limit && start_time > @last_booking_started
      end

      self[:current_booking] = booking
      self[:host_email] = booking["extension_data"]?.try(&.[]?("host_override")) || booking["host"]?
      self[:started_at] = start_time
      self[:ending_at] = ending_at ? ending_at.as_i64 : (start_time + 24.hours.to_i)
      self[:all_day_event] = !ending_at
      self[:event_id] = booking["id"]?

      @expose_for_analytics.each do |binding, path|
        begin
          binding_keys = path.split("->")
          data = booking
          binding_keys.each do |key|
            data = data.dig? key
            break unless data
          end
          self[binding] = data
        rescue error
          logger.warn(exception: error) { "failed to expose #{binding}: #{path} for analytics" }
          self[binding] = nil
        end
      end

      previous_booking_id = @current_meeting_id
      new_booking_id = booking["id"].as_s
      schedule.in(1.second) { check_for_sensors } unless new_booking_id == previous_booking_id
      @current_meeting_id = new_booking_id
    else
      self[:current_booking] = nil
      self[:host_email] = nil
      self[:started_at] = nil
      self[:ending_at] = nil
      self[:all_day_event] = nil
      self[:event_id] = nil

      @expose_for_analytics.each_key do |binding|
        self[binding] = nil
      end
    end

    # We haven't checked the index of `next_booking` exists, hence the `[]?`
    if booking = bookings[next_booking]?
      start_time = booking["event_start"].as_i64

      # is the next meeting pending?
      if start_time <= @pending_before.from_now.to_unix
        # if start time is greater than last started, then no one has checked in yet
        if start_time > @last_booking_started
          next_pending = true
        else
          booked = true
        end
      end
      self[:next_booking] = booking
    else
      self[:next_booking] = nil
    end

    self[:booked] = booked

    # Check if pending is enabled
    if @pending_period.to_i > 0_i64 || @pending_before.to_i > 0_i64
      self[:current_pending] = @current_pending = current_pending
      self[:next_pending] = @next_pending = next_pending
      self[:pending] = current_pending || next_pending

      self[:in_use] = booked && !current_pending
    else
      self[:current_pending] = @current_pending = current_pending = false
      self[:next_pending] = @next_pending = next_pending = false
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
    if @current_pending
      current
    elsif @next_pending
      upcoming
    end
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  protected def to_location_format(events : Enumerable(PlaceCalendar::Event))
    sys = system.config
    events.map do |event|
      event_ends = event.all_day? ? event.event_start.in(@time_zone).at_end_of_day : event.event_end.not_nil!
      {
        location:   :meeting,
        mac:        @calendar_id,
        event_id:   event.id,
        map_id:     sys.map_id,
        sys_id:     sys.id,
        ends_at:    event_ends.to_unix,
        started_at: event.event_start.to_unix,
        private:    !!event.private?,
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

  @sensor_subscription : PlaceOS::Driver::Subscriptions::Subscription? = nil

  protected def check_for_sensors
    drivers = system.implementing(Interface::Sensor)

    if sub = @sensor_subscription
      subscriptions.unsubscribe(sub)
      @sensor_subscription = nil
    end

    # Prefer people count data in a space
    count_data = drivers.sensors("people_count", @sensor_mac).get.flat_map(&.as_a).first?

    if count_data && count_data["module_id"]?.try(&.raw.is_a?(String))
      if !is_stale?(count_data["last_seen"]?.try &.as_i64)
        self[:sensor_name] = count_data["name"].as_s

        # the binding might be multiple layers deep
        binding_keys = count_data["binding"].as_s.split("->")
        binding = binding_keys.shift
        @sensor_subscription = subscriptions.subscribe(count_data["module_id"].as_s, binding) do |_sub, payload|
          data = JSON.parse payload
          binding_keys.each do |key|
            data = data.dig? key
            break unless data
          end
          value = data ? (data.as_f? || data.as_i).to_f : nil
          if value
            self[:people_count] = value
            self[:presence] = value > 0.0
          else
            self[:people_count] = self[:presence] = nil
          end
        end
        @perform_sensor_search = false
      end
    end

    # a people count sensor was stale or not found
    if @perform_sensor_search
      self[:people_count] = nil

      # Fallback to checking for presence
      presence = drivers.sensors("presence", @sensor_mac).get.flat_map(&.as_a).first?
      if presence && presence["module_id"]?.try(&.raw.is_a?(String))
        if !is_stale?(presence["last_seen"]?.try &.as_i64)
          self[:sensor_name] = presence["name"].as_s

          # the binding might be multiple layers deep
          binding_keys = presence["binding"].as_s.split("->")
          binding = binding_keys.shift
          @sensor_subscription = subscriptions.subscribe(presence["module_id"].as_s, binding) do |_sub, payload|
            data = JSON.parse payload
            binding_keys.each do |key|
              data = data.dig? key
              break unless data
            end
            value = data ? (data.as_f? || data.as_i).to_f : nil
            self[:presence] = value ? value > 0.0 : nil
          end
          @perform_sensor_search = false
        else
          self[:sensor_name] = self[:presence] = nil
          @perform_sensor_search = true
        end
      end
    end
  rescue error
    @perform_sensor_search = true
    logger.error(exception: error) { "checking for sensors" }
    self[:people_count] = nil
    self[:presence] = nil
    self[:sensor_name] = nil
    self[:sensor_stale] = true
  end

  def is_stale?(timestamp : Int64?) : Bool
    if timestamp.nil?
      return self[:sensor_stale] = false
    end

    sensor_time = Time.unix(timestamp)
    stale_time = @sensor_stale_minutes.ago

    if sensor_time > stale_time
      self[:sensor_stale] = false
    else
      @perform_sensor_search = true
      self[:sensor_stale] = true
    end
  end

  enum ServiceName
    Google
    Office365
  end

  enum NotifyType
    # resource event changes
    Created # a resource was created (MS only)
    Updated # a resource was updated (in Google this could also mean created)
    Deleted # a resource was deleted

    # subscription lifecycle event (MS only)
    Renew       # subscription was deleted
    Missed      # MS sends this to mean resource event changes were not sent
    Reauthorize # subscription needs reauthorization
  end

  struct NotifyEvent
    include JSON::Serializable

    getter event_type : NotifyType
    getter resource_id : String?
    getter resource_uri : String
    getter subscription_id : String
    getter client_secret : String

    @[JSON::Field(converter: Time::EpochConverter)]
    getter expiration_time : Time
  end

  # TODO:: remove in the future
  struct PlaceCalendar::Subscription
    @client_secret : String | Int64?

    def client_secret
      @client_secret.to_s
    end

    def expired?
      if time = expires_at
        1.hour.from_now >= time
      else
        false
      end
    end
  end

  @subscription : PlaceCalendar::Subscription? = nil
  @push_notification_url : String? = nil
  @push_authority : String? = nil
  @push_service_name : ServiceName? = nil
  @push_monitoring : PlaceOS::Driver::Subscriptions::ChannelSubscription? = nil
  @push_mutex : Mutex = Mutex.new(:reentrant)

  # the API reports that 6 days is the max:
  # Subscription expiration can only be 10070 minutes in the future.
  SUBSCRIPTION_LENGTH = 3.hours

  protected def push_notificaitons_configure
    @push_notification_url = setting?(String, :push_notification_url).presence
    @push_authority = setting?(String, :push_authority).presence

    # load any existing subscriptions
    subscription = setting?(PlaceCalendar::Subscription, :push_subscription)

    if @push_notification_url
      # clear the monitoring if authority changed
      if subscription && subscription.try(&.id) != @subscription.try(&.id) && (monitor = @push_monitoring)
        subscriptions.unsubscribe(monitor)
        @push_monitoring = nil
      end
      @subscription = subscription
      schedule.every(5.minutes + rand(120).seconds) { push_notificaitons_maintain }
      schedule.in(rand(30).seconds) { push_notificaitons_maintain(true) }
    elsif subscription
      push_notificaitons_cleanup(subscription)
    end
  end

  # delete a subscription
  protected def push_notificaitons_cleanup(sub)
    @push_mutex.synchronize do
      logger.debug { "removing subscription" }

      calendar.delete_notifier(sub) if sub
      @subscription = nil
      define_setting(:push_subscription, nil)
    end
  end

  getter sub_renewed_at : Time = 21.minutes.ago

  # creates and maintains a subscription
  protected def push_notificaitons_maintain(force_renew = false) : Nil
    should_force = force_renew && @sub_renewed_at < 20.minutes.ago

    @push_mutex.synchronize do
      subscription = @subscription

      logger.debug { "maintaining push subscription, monitoring: #{!!@push_monitoring}, subscription: #{subscription ? !subscription.expired? : "none"}" }

      return create_subscription unless subscription

      if should_force || subscription.expired?
        # renew subscription
        begin
          logger.debug { "renewing subscription" }
          expires = SUBSCRIPTION_LENGTH.from_now
          sub = calendar.renew_notifier(subscription, expires.to_unix).get
          @subscription = PlaceCalendar::Subscription.from_json(sub.to_json)

          # save the subscription details for processing
          define_setting(:push_subscription, @subscription)
          @sub_renewed_at = Time.local
        rescue error
          logger.error(exception: error) { "failed to renew expired subscription, creating new subscription" }
          @subscription = nil
          schedule.in(1.second) { push_notificaitons_maintain; nil }
        end

        configure_push_monitoring
        return
      end

      configure_push_monitoring if @push_monitoring.nil?
    end
  end

  protected def configure_push_monitoring
    subscription = @subscription.as(PlaceCalendar::Subscription)
    channel_path = "#{subscription.id}/event"

    if old = @push_monitoring
      subscriptions.unsubscribe old
    end

    @push_monitoring = monitor(channel_path) { |_subscription, payload| push_event_occured(payload) }
    logger.debug { "monitoring channel: #{channel_path}" }
  end

  protected def push_event_occured(payload : String)
    logger.debug { "push notification received! #{payload}" }

    notification = NotifyEvent.from_json payload

    secret = @subscription.try &.client_secret
    unless secret && secret == notification.client_secret
      logger.warn { "ignoring notify event with mismatched secret: #{notification.inspect}" }
      return
    end

    case notification.event_type
    in .created?, .updated?, .deleted?
      logger.debug { "polling events as received #{notification.event_type} notification" }
      if resource_id = notification.resource_id
        self[:last_event_notification] = {notification.event_type, resource_id, Time.utc.to_unix}
      end

      # fetch the event from the calendar and signal to staff API
      # staff-api will:
      #  * notify change
      #  * which will link_master_metadata
      begin
        event = calendar.get_event(
          @calendar_id,
          notification.resource_id
        ).get unless notification.event_type.deleted?

        publish("#{@push_authority}/bookings/event", {
          event_id:  notification.resource_id,
          change:    notification.event_type,
          system_id: system.id,
          event:     event,
        }.to_json)
      rescue error
        logger.warn(exception: error) { "fetching booking event on change notification" }
        nil
      end

      poll_events
    in .missed?
      # we don't know the exact event id that changed
      logger.debug { "polling events as a notification was previously missed" }
      poll_events
    in .renew?
      # we need to create a new subscription as the old one has expired
      logger.debug { "a subscription renewal is required" }
      create_subscription
    in .reauthorize?
      logger.debug { "a subscription reauthorization is required" }
      expires = SUBSCRIPTION_LENGTH.from_now
      calendar.reauthorize_notifier(@subscription, expires.to_unix)
    end
  rescue error
    logger.error(exception: error) { "error processing push notification" }
  end

  protected def create_subscription
    @push_mutex.synchronize do
      @push_service_name = service_name = @push_service_name || ServiceName.parse(calendar.calendar_service_name.get.as_s)

      # different resource routes for the different services
      case service_name
      in .google?
        resource = "/calendars/#{calendar_id}/events"
      in .office365?
        resource = "/users/#{calendar_id}/events"
      in Nil
        raise "service name not known, waiting for "
      end

      logger.debug { "registering for push notifications! #{resource}" }

      # create a new secret and subscription
      expires = SUBSCRIPTION_LENGTH.from_now
      push_secret = "a#{Random.new.hex(4)}"
      sub = calendar.create_notifier(resource, @push_notification_url, expires.to_unix, push_secret, @push_notification_url).get
      @subscription = PlaceCalendar::Subscription.from_json(sub.to_json)

      # save the subscription details for processing
      define_setting(:push_subscription, @subscription)
      @sub_renewed_at = Time.local

      configure_push_monitoring
    end
  end
end
