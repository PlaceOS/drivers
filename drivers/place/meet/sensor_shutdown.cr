require "placeos-driver"

class Place::SensorShutdown < PlaceOS::Driver
  descriptive_name "PlaceOS Idle Shutdown"
  generic_name :IdleShutdown
  description "works in conjunction with the Bookings driver to decide when a room should shutdown"

  accessor bookings : Bookings_1
  accessor av_control : System_1

  default_settings({
    timeout_ad_hoc: 15,
    timeout_booked: 30,
  })

  @sensor_stale : Bool = false

  getter? event_in_progress : Bool = false
  getter? people_present : Bool = false
  getter? sensor_stale : Bool = false
  getter? room_powered_on : Bool = false

  getter? timer_active : Bool = false
  @timer_time : Time::Span? = nil
  @timer_started : Time::Span = 0.seconds
  @shutdown_count : Int64 = 0_i64

  @timeout_ad_hoc : Time::Span = 15.minutes
  @timeout_booked : Time::Span = 30.minutes
  @state_change_mutex : Mutex = Mutex.new(:reentrant)

  def on_update
    timeout_ad_hoc = setting?(UInt32, :timeout_ad_hoc) || 15_u32.minutes
    timeout_booked = setting?(UInt32, :timeout_booked) || 30_u32.minutes

    subscriptions.clear
    bookings.subscribe(:status) { |_sub, status| update_status(status != "\"free\"") }
    bookings.subscribe(:sensor_stale) { |_sub, sensor_stale| update_stale_state(sensor_stale == "true") }
    bookings.subscribe(:presence) { |_sub, presence| update_presence(presence == "true") }
    av_control.subscribe(:active) { |_sub, active| update_room_power_state(active == "true") }
  end

  protected def update_status(busy : Bool)
    return if event_in_progress? == busy

    logger.debug { "> event in progress: #{busy}" }
    self[:event_in_progress] = @event_in_progress = busy
    @state_change_mutex.synchronize { apply_state_changes }
  end

  protected def update_presence(state : Bool)
    return if people_present? == state

    logger.debug { "> people present: #{state}" }
    self[:people_present] = @people_present = state
    @state_change_mutex.synchronize { apply_state_changes }
  end

  protected def update_stale_state(stale : Bool)
    return if sensor_stale? == stale

    logger.debug { "> sensor state change: #{stale}" }
    @sensor_stale = stale
    @state_change_mutex.synchronize { apply_state_changes }
  end

  protected def update_room_power_state(powered : Bool)
    return if room_powered_on? == powered

    logger.debug { "> power state change: #{powered}" }
    @room_powered_on = powered
    @state_change_mutex.synchronize { apply_state_changes }
  end

  protected def clear_timer(update_status : Bool = true)
    @state_change_mutex.synchronize do
      @timer_active = false
      @timer_time = nil
      schedule.clear

      if update_status
        self[:timer_active] = false
        self[:timer_started] = nil
      end
    end
  end

  protected def apply_state_changes
    if sensor_stale?
      clear_timer
      logger.warn { "possible sensor failure, ignoring state" }
      return
    end

    if !room_powered_on?
      clear_timer
      logger.debug { "room powered off, clearing schedule" }
      return
    end

    if people_present?
      clear_timer
      logger.debug { "people detected, clearing schedule" }
      return
    end

    timeout = if event_in_progress?
                @timeout_booked
              else
                @timeout_ad_hoc
              end

    if timer_active?
      if @timer_time == timeout
        logger.debug { "timer already active, ignoring event" }
        return
      else
        elapsed = Time.monotonic - @timer_started
        remaining = timeout - elapsed

        if remaining.positive?
          timeout = remaining
        else
          logger.info { "new timeout period and already idle for that amount of time" }
          return perform_shutdown
        end
      end
    end

    clear_timer(update_status: false)
    schedule.in(timeout) { perform_shutdown }
    self[:timer_active] = @timer_active = true
    self[:timer_started] = Time.utc.to_unix
    @timer_time = timeout
    @timer_started = Time.monotonic
    logger.debug { "timer started, shutdown in #{timeout}" }
  end

  protected def perform_shutdown
    clear_timer
    av_control.power false
    @shutdown_count += 1_i64
    self[:last_idle_shutdown] = Time.utc.to_unix
    self[:idle_shutdowns] = @shutdown_count
    logger.info { "System ilde timeout, shutdown requested" }
  end
end
