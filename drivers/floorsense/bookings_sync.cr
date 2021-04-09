module Floorsense; end

require "uri"
require "json"
require "oauth2"
require "placeos-driver/interface/locatable"
require "./models"

class Floorsense::BookingsSync < PlaceOS::Driver
  descriptive_name "Floorsense Bookings Sync"
  generic_name :FloorsenseBookingSync
  description %(syncs PlaceOS bookings with floorsense booking system)

  accessor floorsense : Floorsense_1
  accessor staff_api : StaffAPI_1

  default_settings({
    floor_mappings: {
      "planid": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
    time_zone:          "GMT",
    poll_rate:          3,
    key_prefix:         "desk-",
    strip_leading_zero: true,
    zero_padding_size:  7,
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  # Level zone => plan_id
  @zone_mappings : Hash(String, String) = {} of String => String
  # Level zone => building_zone
  @building_mappings : Hash(String, String?) = {} of String => String?

  @booking_type : String = "desk"
  @key_prefix : String = "desk-"
  @strip_leading_zero : Bool = true
  @zero_padding_size : Int32 = 7
  @poll_rate : Time::Span = 3.seconds
  @time_zone : Time::Location = Time::Location.load("GMT")

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      booking_changed(Booking.from_json(payload))
    end
    on_update
  end

  def on_update
    @key_prefix = setting?(String, :key_prefix) || ""
    @booking_type = setting?(String, :booking_type).presence || "desk"
    @strip_leading_zero = setting?(Bool, :strip_leading_zero) || false
    @zero_padding_size = setting?(Int32, :zero_padding_size) || 7

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @poll_rate = (setting?(Int32, :poll_rate) || 3).seconds

    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @floor_mappings.each do |plan_id, details|
      level = details[:level_id]
      @building_mappings[level] = details[:building_id]
      @zone_mappings[level] = plan_id
    end

    time_zone = setting?(String, :calendar_time_zone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    schedule.clear
    schedule.in(500.milliseconds) { check_floorsense_log }
    schedule.every(@poll_rate) { check_floorsense_log }

    # between polls, sync the bookings
    schedule.in(@poll_rate / 2) do
      schedule.every(@poll_rate * 10) { sync_bookings }
      sync_bookings
    end
  end

  # ===================================
  # Desk ID manipulation
  # ===================================
  def to_place_asset_id(key : String)
    key = key.lstrip('0') if @strip_leading_zero
    "#{@key_prefix}#{key}"
  end

  def to_floor_key(asset_id : String)
    asset_id = asset_id.lstrip(@key_prefix) if @key_prefix.presence
    asset_id = asset_id.ljust(@zero_padding_size, '0') if @strip_leading_zero
    asset_id
  end

  # ===================================
  # Polling for events
  # ===================================
  @last_event_id : Int64? = nil
  @last_event_at : Int64 = 0_i64

  def check_floorsense_log : Nil
    last_event_id = @last_event_id
    if last_event_id.nil?
      recent = floorsense.event_log({49, 50, 53}).get.as_a
      if !recent.empty?
        last = recent.last
        @last_event_id = last["eventid"].as_i64
        @last_event_at = last["eventtime"].as_i64
      end
      return
    end

    events = Array(LogEntry).from_json floorsense.event_log(
      codes: {49, 50, 53},
      after: @last_event_at,
      limit: 500
    ).get.to_json

    # it returns all the events that happened at the time specified
    # some of these might have happened before this event id
    # and it'll always return the last seen event id
    events.reject! { |event| event.eventid <= last_event_id }
    return if events.empty?

    @last_event_id = events.last.eventid
    events.each do |event|
      begin
        booking = BookingStatus.from_json floorsense.get_booking(event.bkid).get.to_json
        floor_details = @floor_mappings[booking.planid.to_s]?
        next unless floor_details

        case event.code
        when 49 # BOOKING_CREATE (ad-hoc?)
          user_email = booking.user.not_nil!.email.try &.downcase

          if user_email.nil?
            logger.warn { "no user email defined for floorsense user #{booking.user.not_nil!.name}" }
            next
          end

          user = staff_api.user(user_email).get
          user_id = user["id"]
          user_name = user["name"]

          staff_api.create_booking(
            booking_start: booking.start,
            booking_end: booking.finish,
            time_zone: @time_zone.to_s,
            booking_type: @booking_type,
            asset_id: to_place_asset_id(booking.key),
            user_id: user_id,
            user_email: user_email,
            user_name: user_name,
            zones: [floor_details[:building_id]?, floor_details[:level_id]].compact,
            checked_in: true,
            extension_data: {
              floorsense_id: event.bkid,
            },
          ).get
        when 50 # BOOKING_RELEASE (booking ended)
          # ignore bookings that were cancelled outside of today
          next if booking.released >= booking.finish || booking.released <= booking.start

          # find placeos booking
          if place_booking = get_place_booking(booking, floor_details)
            # change the placeos end time if the booking has started
            staff_api.update_booking(
              booking_id: place_booking.id,
              booking_end: booking.released
            ).get
          else
            logger.warn { "no booking found for released booking #{booking.booking_id}" }
          end
        when 51 # BOOKING_UPDATE (booking changed)
        when 52 # BOOKING_ACTIVATE (advanced booking - i.e. tomorrow)
        when 53 # BOOKING_CONFIRM (checked in)
          # find placeos booking (should only fail here for adhoc which are already checked in)
          begin
            if desc = booking.desc
              place_booking = Booking.from_json staff_api.get_booking(desc.to_i64).get.to_json
              staff_api.booking_check_in(place_booking.id, booking.confirmed)
            end
          rescue ArgumentError
            # was an adhoc booking
          end
        end
      rescue error
        logger.warn(exception: error) { "while processing #{event.eventid}\n#{event.inspect}" }
      end
    end
  end

  protected def get_place_booking(freespace_booking, floor_details) : Booking?
    if desc = freespace_booking.desc
      Booking.from_json staff_api.get_booking(desc.to_i64).get.to_json
    else
      search_place_booking(freespace_booking, floor_details)
    end
  rescue ArgumentError
    # in case the description was unexpectedly not an int64 (adhoc for instance)
    search_place_booking(freespace_booking, floor_details)
  end

  protected def search_place_booking(freespace_booking, floor_details)
    user_email = freespace_booking.user.not_nil!.email.try &.downcase

    if user_email.nil?
      logger.warn { "no user email defined for floorsense user #{freespace_booking.user.not_nil!.name}" }
      return nil
    end

    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: freespace_booking.start,
      period_end: freespace_booking.finish,
      zones: {floor_details[:level_id]},
      email: user_email
    ).get.as_a

    bookings.compact_map { |book|
      booking = Booking.from_json(book.to_json)
      booking.rejected ? nil : booking
    }.first?
  end

  # ===================================
  # Monitoring desk bookings
  # ===================================
  protected def booking_changed(event)
    return unless event.booking_type == @booking_type
    matching_zones = @zone_mappings.keys & event.zones
    return if matching_zones.empty?

    logger.debug { "booking event is in a matching zone" }

    sync_floor(matching_zones.first)
  end

  def sync_bookings
    @zone_mappings.keys.each { |zone_id| sync_floor(zone_id) }
  end

  def sync_floor(zone : String)
    plan_id = @zone_mappings[zone]?
    if plan_id.nil?
      logger.warn { "unknown plan ID for zone #{zone}" }
      return 0
    end
    floor_details = @floor_mappings[plan_id]

    place_bookings = placeos_bookings(zone)
    sense_bookings = floorsense_bookings(zone)

    adhoc = [] of BookingStatus
    other = [] of BookingStatus

    sense_bookings.each do |booking|
      if booking.booking_type == "adhoc"
        adhoc << booking
      else
        other << booking
      end
    end

    place_booking_checked = Set(Int64).new
    release_floor_bookings = [] of BookingStatus
    release_place_bookings = [] of Tuple(Booking, Int64)
    create_place_bookings = [] of BookingStatus
    create_floor_bookings = [] of Booking

    # adhoc bookings need to be added to PlaceOS
    adhoc.each do |floor_booking|
      found = false
      place_bookings.each do |booking|
        # match using extenstion data
        if (ext_data = booking.extension_data) && (floor_id = ext_data["floorsense_id"]?.try(&.as_s)) && floor_id == floor_booking.booking_id
          found == true
          place_booking_checked << booking.id
        else
          next
        end

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          # need to change end time of this booking
          release_place_bookings << {booking, floor_booking.released}
        end

        break
      end

      if !found && floor_booking.released == 0_i64
        create_place_bookings << floor_booking
      end
    end

    # what bookings need to be added to floorsense
    place_bookings.each do |booking|
      next if place_booking_checked.includes?(booking.id)

      found = false
      other.each do |floor_booking|
        next unless floor_booking.desc == booking.id.to_s
        found == true

        # TODO:: check for booking changes?
        # we currently are not and probably shouldn't be moving bookings to different days

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          # need to change end time of this booking
          release_place_bookings << {booking, floor_booking.released}
        end

        break
      end

      create_floor_bookings << booking unless found || booking.rejected
    end

    # update floorsense
    local_floorsense = floorsense
    release_floor_bookings.each { |floor_booking| local_floorsense.release_booking(floor_booking.booking_id) }
    create_floor_bookings.each do |booking|
      floor_user = begin
        get_floorsense_user(booking.user_id)
      rescue error
        logger.warn(exception: error) { "unable to find or create user #{booking.user_id} (#{booking.user_email}) in floorsense" }
        next
      end

      # We need a floorsense user to own the booking
      # floor_user = local_floorsense.user_list(booking.user_email).get.as_a.first?

      local_floorsense.create_booking(
        user_id: floor_user,
        plan_id: plan_id,
        key: to_floor_key(booking.asset_id),
        description: booking.id.to_s,
        starting: booking.booking_start,
        ending: booking.booking_end
      )
    end

    # update placeos
    local_staff_api = staff_api
    release_place_bookings.each do |booking, released|
      local_staff_api.update_booking(
        booking_id: booking.id,
        booking_end: released
      )
    end
    create_place_bookings.each do |booking|
      user_email = booking.user.not_nil!.email.try &.downcase

      if user_email.nil?
        logger.warn { "no user email defined for floorsense user #{booking.user.not_nil!.name}" }
        next
      end

      user = local_staff_api.user(user_email).get
      user_id = user["id"]
      user_name = user["name"]

      local_staff_api.create_booking(
        booking_start: booking.start,
        booking_end: booking.finish,
        booking_type: @booking_type,
        asset_id: to_place_asset_id(booking.key),
        user_id: user_id,
        user_email: user_email,
        user_name: user_name,
        zones: [floor_details[:building_id]?, floor_details[:level_id]].compact,
        extension_data: {
          floorsense_id: booking.booking_id,
        },
      )
    end

    # number of bookings checked
    place_bookings.size + adhoc.size
  end

  # ===================================
  # Sync Users
  # ===================================
  def get_floorsense_user(placeos_user_id : String) : String
    users = floorsense.user_list(description: placeos_user_id).get.as_a
    if user = users.first?
      return user["uid"].as_s
    end

    # User not found, we need to create a user
    place_user = staff_api.user(placeos_user_id).get
    name = place_user["name"].as_s
    email = place_user["email"].as_s
    card_number = place_user["card_number"]?.try(&.as_s)

    # Add the card number to the user
    user_id = floorsense.create_user(name, email, placeos_user_id).get["uid"].as_s
    if card_number.presence
      floorsense.delete_rfid(card_number)
      floorsense.create_rfid(user_id, card_number)
    end
    user_id
  end

  # ===================================
  # Booking Queries
  # ===================================
  def floorsense_bookings(zone_id : String)
    logger.debug { "querying floorsense bookings in zone #{zone_id}" }

    plan_id = @zone_mappings[zone_id]?
    return [] of BookingStatus unless plan_id

    current = [] of BookingStatus
    start_of_day = Time.local(@time_zone).at_beginning_of_day
    tomorrow_night = (start_of_day.at_end_of_day + 1.hour).at_end_of_day

    raw_bookings = floorsense.bookings(plan_id, start_of_day.to_unix, tomorrow_night.to_unix).get.to_json
    Hash(String, Array(BookingStatus)).from_json(raw_bookings).each do |desk_id, bookings|
      current << bookings.first if bookings.size > 0
    end
    current
  end

  def placeos_bookings(zone_id : String)
    start_of_day = Time.local(@time_zone).at_beginning_of_day
    tomorrow_night = (start_of_day.at_end_of_day + 1.hour).at_end_of_day

    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: start_of_day,
      period_end: tomorrow_night,
      zones: {zone_id}
    ).get.as_a

    bookings.map { |book| Booking.from_json(book.to_json) }
  end

  class Booking
    include JSON::Serializable

    # This is to support events
    property action : String?

    property id : Int64
    property booking_type : String
    property booking_start : Int64
    property booking_end : Int64
    property timezone : String?

    # events use resource_id instead of asset_id
    property asset_id : String?
    property resource_id : String?

    def asset_id : String
      (@asset_id || @resource_id).not_nil!
    end

    property user_id : String
    property user_email : String
    property user_name : String

    property zones : Array(String)

    property checked_in : Bool?
    property rejected : Bool?

    property extension_data : JSON::Any?

    def in_progress?
      now = Time.utc.to_unix
      now >= @booking_start && now < @booking_end
    end
  end
end
