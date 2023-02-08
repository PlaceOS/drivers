require "placeos-driver"

class Place::AutoDeskCheckin < PlaceOS::Driver
  descriptive_name "Auto Desk Checkin"
  generic_name :AutoDeskCheckin
  description %(automatically checks in desks that will be in use in the near future)

  accessor staff_api : StaffAPI_1

  default_settings({
    check_in_zones:             ["zone-id1", "zone-id2"],
    hours_before_booking_start: 1,
    booking_category:           "desk",
  })

  def on_load
    on_update
  end

  @time_period : Time::Span = 1.hour
  @booking_category : String = "desk"
  @zones : Array(String) = [] of String

  def on_update
    @zones = setting(Array(String), :check_in_zones)
    @time_period = setting(Int32, :hours_before_booking_start).hours
    @booking_category = setting(String, :booking_category)

    schedule.clear
    schedule.every(5.minutes) { fetch_and_check_in }
  end

  def fetch_and_check_in
    period_start = Time.utc.to_unix
    period_end = @time_period.from_now.to_unix
    booking_ids = staff_api.query_bookings(@booking_category, period_start, period_end, @zones, checked_in: false).get.as_a.map { |booking| booking["id"].as_i64 }

    success = 0
    failed = [] of Int64

    booking_ids.each do |id|
      begin
        staff_api.booking_check_in(id, true, "auto-checkin").get
        success += 1
      rescue error
        failed << id
        logger.debug(exception: error) { "failed to check-in booking #{id}" }
      end
    end

    "checked-in #{success} bookings, failed #{failed.size}: #{failed}"
  end
end
