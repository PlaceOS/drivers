require "placeos-driver"
require "./booking_model"

class Place::AutoReleaseLocker < PlaceOS::Driver
  descriptive_name "PlaceOS Auto Release Locker"
  generic_name :AutoReleaseLocker
  description %(automatic release locker on specified interval)

  default_settings({
    booking_type:      "locker",
    release_schedule:  "0 23 * * 5",
    time_window_hours: 1,
  })

  accessor staff_api : StaffAPI_1

  @booking_type : String = "locker"
  @release_schedule : String = "0 23 * * 5"
  @time_window_hours : Int32 = 1

  def on_update
    @timezone = nil
    @building_id = nil
    @booking_type = setting?(String, :booking_type).presence || "locker"
    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @release_schedule = setting(String, :release_schedule)

    schedule.clear
    schedule_cron
  end

  protected def schedule_cron : Nil
    schedule.cron(@release_schedule, timezone) { release_lockers }
  rescue error
    logger.warn(exception: error) { "failed to schedule cron job" }
    schedule.in(1.minute) { schedule_cron }
  end

  # Finds the building ID for the current location services object
  getter building_id : String do
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    raise error
  end

  protected getter timezone : Time::Location do
    tz = config.control_system.try(&.timezone) || staff_api.zone(building_id).get["timezone"].as_s
    Time::Location.load(tz)
  end

  def get_bookings : Array(Booking)
    bookings = Array(Booking).from_json staff_api.query_bookings(
      type: @booking_type,
      period_start: Time.utc.to_unix,
      period_end: (Time.utc + @time_window_hours.hours).to_unix,
      zones: [building_id],
    ).get.to_json
    logger.debug { "found #{bookings.size} #{@booking_type} bookings" }

    bookings
  rescue error
    logger.warn(exception: error) { "unable to obtain list of #{@booking_type} bookings" }
    [] of Booking
  end

  @[Security(Level::Support)]
  def release_lockers
    bookings = get_bookings
    released = 0
    bookings.each do |booking|
      logger.debug { "releasing booking #{booking.id} as it is within the time_after window" }
      begin
        staff_api.update_booking(booking.id, recurrence_end: booking.booking_end).get if booking.instance
        staff_api.booking_check_in(booking.id, false, "auto-release", instance: booking.instance).get
        released += 1
      rescue error
        logger.warn(exception: error) { "unable to release #{@booking_type} with booking id #{booking.id} (inst: #{booking.instance})" }
      end
    end
    results = {total: bookings.size, released: released}
    logger.debug { results.inspect }
    results
  end
end
