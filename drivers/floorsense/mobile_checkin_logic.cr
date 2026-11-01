require "placeos-driver"
require "../place/desk_source"

class Floorsense::MobileCheckinLogic < PlaceOS::Driver
  descriptive_name "Floorsense Mobile Checkin Logic"
  generic_name :MobileCheckin
  description %(provides methods for emulating a card swipe using a mobile phone)

  accessor booking_sync : FloorsenseBookingSync_1
  accessor staff_api : StaffAPI_1

  include Place::DeskSource

  default_settings({
    time_zone:         "Australia/Sydney",
    booking_period:    120,
    meta_ext_mappings: {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },

    # read desks from `_DESKS_` assets instead of the `desks` zone metadata
    use_desk_assets: false,
  })

  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @booking_period : Time::Span? = nil
  @meta_ext_mappings : Hash(String, String) = {} of String => String

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

    now = Time.utc.to_unix
    booking = staff_api.query_bookings(type: "desk", zones: [level_zone]).get.as_a.find do |book|
      book["asset_id"].as_s == place_desk && book["booking_start"].as_i64 <= now && book["booking_end"].as_i64 > now
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
        if desk = placeos_desk_metadata(level_zone, place_desk)
          return "forbidden" unless desk.bookable?

          title = desk.name

          @meta_ext_mappings.each do |meta_key, ext_key|
            if value = desk.value(meta_key)
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

  def placeos_desk_metadata(zone_id : String, asset_id : String) : Desk?
    level_desks(zone_id).find { |desk| desk.id == asset_id }
  end
end
