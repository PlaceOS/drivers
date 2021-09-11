require "placeos-driver"

class Floorsense::MobileCheckinLogic < PlaceOS::Driver
  descriptive_name "Floorsense Mobile Checkin Logic"
  generic_name :MobileCheckin
  description %(provides methods for emulating a card swipe using a mobile phone)

  accessor booking_sync : FloorsenseBookingSync_1
  accessor staff_api : StaffAPI_1

  default_settings({
    time_zone: "Australia/Sydney",
  })

  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")

  def on_load
    on_update
  end

  def on_update
    time_zone = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence
    @time_zone = Time::Location.load(time_zone) if time_zone
  end

  def eui64_scanned(id : String, user_id : String, booking_minutes : Int32? = nil)
    logger.debug { "#{user_id} scanned mac #{id}" }

    desk_details = booking_sync.eui64_to_desk_id(id).get
    level_zone = desk_details["level"].as_s
    build_zone = desk_details["building_id"]?.try &.as_s
    place_desk = desk_details["desk_id"].as_s

    logger.debug { "located #{place_desk} for #{user_id}" }

    booking = staff_api.query_bookings(type: "desk", zones: [level_zone]).get.as_a.find do |book|
      book["asset_id"].as_s == place_desk
    end

    if booking
      owner_id = booking["user_id"].as_s
      if owner_id == user_id
        # check in or out depending on the current booking status
        checkin_out = !booking["checked_in"].as_bool
        booking_id = booking["id"].as_s
        logger.debug { "found existing booking #{booking_id} with current checked-in status #{!checkin_out}" }
        staff_api.booking_check_in(booking_id, checkin_out).get.as_bool

        checkin_out ? "checked-in" : "checked-out"
      else
        # Desk is booked for another user
        logger.debug { "#{user_id} scanned desk owned by #{owner_id}" }
        "forbidden"
      end
    else
      # Perform an adhoc booking
      now = Time.local(@time_zone)
      future = booking_minutes ? (now + booking_minutes.minutes) : now.at_end_of_day

      user_details = staff_api.user(user_id).get
      zones = [level_zone]
      zones << build_zone if build_zone

      logger.debug { "creating new booking for #{user_id} on #{place_desk}" }

      staff_api.create_booking(
        booking_type: "desk",
        asset_id: place_desk,
        user_id: user_id,
        user_email: user_details["email"],
        user_name: user_details["name"],
        zones: zones,
        booking_start: now.to_unix,
        booking_end: future.to_unix,
        checked_in: true,
        approved: true,
        time_zone: @time_zone.name
      ).get
      "adhoc"
    end
  end
end
