require "placeos-driver"
require "./booking_model"

class Place::AutoReleaseLocker < PlaceOS::Driver
  descriptive_name "PlaceOS Auto Release Locker"
  generic_name :AutoReleaseLocker
  description %(automatic release locker on specified interval)

  default_settings({
    timezone:          "Australia/Sydney",
    booking_type:      "locker",
    release_schedule:  "0 23 * * 5",
    time_window_hours: 1,
  })

  accessor staff_api : StaffAPI_1

  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @booking_type : String = "locker"
  @release_schedule : String? = nil
  @time_window_hours : Int32 = 1

  def on_update
    @release_schedule = setting?(String, :release_schedule).presence
    timezone = setting?(String, :timezone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)
    @booking_type = setting?(String, :booking_type).presence || "locker"
    @time_window_hours = setting?(Int32, :time_window_hours) || 1

    schedule.clear

    if release = @release_schedule
      schedule.cron(release, @timezone) { release_lockers }
    end
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  @[Security(Level::Support)]
  def get_bookings : Array(Booking)
    results = [] of Booking
    bookings = Array(Booking).from_json staff_api.query_bookings(
      type: @booking_type,
      period_start: Time.utc.to_unix,
      period_end: (Time.utc + @time_window_hours.hours).to_unix,
      zones: [get_building_id],
    ).get.to_json
    results = bookings.select { |booking| booking.checked_in }

    logger.debug { "found #{results.size} #{@booking_type} bookings" }

    results
  rescue error
    logger.warn(exception: error) { "unable to obtain list of #{@booking_type} bookings" }
    [] of Booking
  end

  def release_lockers
    bookings = get_bookings
    released = 0
    bookings.each do |booking|
      logger.debug { "releasing booking #{booking.id} as it is within the time_after window" }
      begin
        staff_api.update_booking(booking_id: booking.id, booking_end: Time.utc.to_unix, checked_in: false)
        released += 1
      rescue error
        logger.warn(exception: error) { "unable to release #{@booking_type} with booking id #{booking.id}" }
      end
    end
    {total: bookings.size, released: released}
  end
end
