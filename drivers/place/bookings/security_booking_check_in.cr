require "placeos-driver"
require "place_calendar"
require "placeos-driver/interface/door_security"

class Place::SecurityBookingCheckin < PlaceOS::Driver
  descriptive_name "Security based Booking Checkin"
  generic_name :SecurityBookingCheckin
  description %(Checks in users to bookings based on swipe card events in the security system)

  default_settings({
    # the channel id we're looking for events on
    organization_id: "event",

    # booking types we want to check in
    booking_types: ["desk"],
  })

  def on_update
    @booking_types = setting(Array(String), :booking_types)
    time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(time_zone_string)
    @building_id = nil

    subscriptions.clear
    org_id = setting?(String, :organization_id) || "event"
    monitor("security/#{org_id}/door") { |_subscription, payload| door_event(payload) }
  end

  @booking_types : Array(String) = [] of String
  @time_zone : Time::Location = Time::Location.load("GMT")

  accessor staff_api : StaffAPI_1

  getter building_id : String { get_building_id.not_nil! }

  def get_building_id : String
    building_setting = setting?(String, :building_zone_override)
    return building_setting if building_setting && building_setting.presence
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  end

  getter event_count : UInt64 = 0_u64
  getter check_ins : UInt64 = 0_u64
  getter matched_users : UInt64 = 0_u64

  @[Security(Level::Administrator)]
  def door_event(json : String)
    logger.debug { "new door event detected: #{json}" }
    event = Interface::DoorSecurity::DoorEvent.from_json(json)
    @event_count += 1_u64

    now = Time.local(@time_zone).at_beginning_of_day
    end_of_day = now.in(@time_zone).at_end_of_day - 2.hours
    building = building_id

    @booking_types.each do |booking_type|
      if email = event.user_email.presence
        staff_user = staff_api.user(email.strip.downcase).get rescue nil
        if staff_user
          email = staff_user["email"].as_s
          @matched_users += 1_u64
        end

        # find any bookings that user may have
        bookings = staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {building}, type: booking_type, email: email).get.as_a
        logger.debug { "found #{bookings.size} of #{booking_type} for #{email}" }

        bookings.each do |booking|
          if !booking["checked_in"].as_bool?
            logger.debug { "  --  checking in #{booking_type} for #{email}" }
            @check_ins += 1_u64
            staff_api.booking_check_in(booking["id"], true, "security-access", instance: booking["instance"]?)
          else
            logger.debug { "  --  skipping #{booking_type} for #{email} as already checked-in" }
          end
        end
      end
    end
  end
end
