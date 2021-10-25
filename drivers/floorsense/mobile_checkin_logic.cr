require "placeos-driver"

class Floorsense::MobileCheckinLogic < PlaceOS::Driver
  descriptive_name "Floorsense Mobile Checkin Logic"
  generic_name :MobileCheckin
  description %(provides methods for emulating a card swipe using a mobile phone)

  accessor booking_sync : FloorsenseBookingSync_1
  accessor staff_api : StaffAPI_1

  default_settings({
    time_zone:         "Australia/Sydney",
    booking_period:    120,
    meta_ext_mappings: {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },
  })

  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @booking_period : Time::Span? = nil
  @meta_ext_mappings : Hash(String, String) = {} of String => String

  def on_load
    on_update
  end

  def on_update
    time_zone = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence
    @time_zone = Time::Location.load(time_zone) if time_zone
    @booking_period = setting?(Int32, :booking_period).try &.minutes
    @meta_ext_mappings = setting?(Hash(String, String), :meta_ext_mappings) || {} of String => String
  end

  def eui64_scanned(id : String, user_id : String, booking_minutes : Int32? = nil)
    logger.debug { "#{user_id} scanned mac #{id}" }

    desk_details = booking_sync.eui64_to_desk_id(id).get
    raise "could not find eui64 id: #{id}" if desk_details.raw.nil?

    logger.debug { "desk details found: #{desk_details.inspect}" }

    level_zone = desk_details["level"].as_s
    place_desk = desk_details["desk_id"].as_s
    building_raw = desk_details["building_id"]?.try &.raw
    build_zone = building_raw.try &.as(String)

    logger.debug { "located #{place_desk} for #{user_id}" }

    booking = staff_api.query_bookings(type: "desk", zones: [level_zone]).get.as_a.find do |book|
      book["asset_id"].as_s == place_desk
    end

    if booking
      owner_id = booking["user_id"].as_s
      if owner_id == user_id
        # check in or out depending on the current booking status
        checkin_out = !booking["checked_in"].as_bool
        booking_id = booking["id"].as_i64
        logger.debug { "found existing booking #{booking_id} with current checked-in status #{!checkin_out}" }

        if checkin_out
          staff_api.booking_check_in(booking_id, true).get.as_bool
          "checked-in"
        else
          # 1 min ago to account for any server clock sync issues
          now = 1.minute.ago.to_unix
          staff_api.update_booking(
            booking_id: booking_id,
            booking_end: now,
            checked_in: false
          ).get
          "checked-out"
        end
      else
        # Desk is booked for another user
        logger.debug { "#{user_id} scanned desk owned by #{owner_id}" }
        "forbidden"
      end
    else
      # Perform an adhoc booking
      booking_period = booking_minutes.try(&.minutes) || @booking_period
      now = Time.local(@time_zone)
      future = booking_period ? (now + booking_period) : now.at_end_of_day

      user_details = staff_api.user(user_id).get
      zones = [level_zone]
      zones.unshift(build_zone) if build_zone

      # Grab additional details out of the desk metadata
      title = place_desk
      ext_data = {} of String => JSON::Any
      begin
        logger.debug { "obtaining metadata for desk #{place_desk} on level #{level_zone}" }
        if desk_details = placeos_desk_metadata(level_zone, place_desk)
          # check if the desk is bookable
          if bookable = desk_details["bookable"]?
            return "forbidden" if (bookable.as_s?.try(&.upcase) == "FALSE") || (bookable.as_bool? == false)
          end

          title = desk_details["name"]?.try(&.as_s) || place_desk

          @meta_ext_mappings.each do |meta_key, ext_key|
            if value = desk_details[meta_key]?
              ext_data[ext_key] = value
            end
          end
        else
          logger.warn { "desk details not found!" }
        end
      rescue error
        logger.warn(exception: error) { "obtaining desk metadata" }
      end

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
        title: title,
        time_zone: @time_zone.name,
        extension_data: ext_data
      ).get
      "adhoc"
    end
  end

  def placeos_desk_metadata(zone_id : String, asset_id : String)
    metadata = staff_api.metadata(
      zone_id,
      "desks"
    ).get["desks"]["details"].as_a

    metadata.each do |desk|
      place_id = desk["id"]?.try(&.as_s)
      next unless place_id
      return desk.as_h if place_id == asset_id
    end
    nil
  end
end
