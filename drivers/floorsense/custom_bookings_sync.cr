require "uri"
require "json"
require "oauth2"
require "placeos-driver"
require "placeos-driver/interface/locatable"
require "./models"

class Floorsense::CustomBookingsSync < PlaceOS::Driver
  descriptive_name "Floorsense Custom Bookings Sync"
  generic_name :FloorsenseBookingSync
  description %(syncs PlaceOS desk bookings with floorsense booking system)

  accessor floorsense : Floorsense_1
  accessor staff_api : StaffAPI_1
  accessor area_management : AreaManagement_1
  accessor locations : FloorsenseLocationService_1

  bind Floorsense_1, :event_49, :booking_created
  bind Floorsense_1, :event_50, :booking_released
  bind Floorsense_1, :event_53, :booking_confirmed

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
    user_lookup:        "staff_id",

    floorsense_lookup_key:   "floorsensedeskid",
    create_floorsense_users: false,
    debug_logging:           false,

    # Keys to map into ad-hoc bookings
    meta_ext_mappings: {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },
  })

  @meta_ext_mappings : Hash(String, String) = {} of String => String
  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  # Level zone => plan_id
  @zone_mappings : Hash(String, String) = {} of String => String
  # Level zone => building_zone
  @building_mappings : Hash(String, String?) = {} of String => String?
  # Desk ID mappings cache
  @desk_mapping_cache : Hash(String, Hash(String, DeskMeta)) = {} of String => Hash(String, DeskMeta)
  @floorsense_lookup_key : String = "floorsensedeskid"
  @create_floorsense_users : Bool = false

  @booking_type : String = "desk"
  @key_prefix : String = "desk-"
  @strip_leading_zero : Bool = true
  @zero_padding_size : Int32 = 7
  @poll_rate : Time::Span = 3.seconds
  @time_zone : Time::Location = Time::Location.load("GMT")
  @user_lookup : String = "staff_id"
  @debug_logging : Bool = false

  @sync_lock = Mutex.new

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      log { "received booking changed event #{payload}" }
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
    @user_lookup = setting?(String, :user_lookup).presence || "staff_id"
    @debug_logging = setting?(Bool, :debug_logging) || false

    @floorsense_lookup_key = setting?(String, :floorsense_lookup_key).presence || "floorsensedeskid"
    @create_floorsense_users = setting?(Bool, :create_floorsense_users) || false

    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @floor_mappings.each do |plan_id, details|
      level = details[:level_id]
      @building_mappings[level] = details[:building_id]
      @zone_mappings[level] = plan_id
    end

    @meta_ext_mappings = setting?(Hash(String, String), :meta_ext_mappings) || {} of String => String

    time_zone = setting?(String, :time_zone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    schedule.clear

    # schedule.in(500.milliseconds) { @sync_lock.synchronize { check_floorsense_log } }
    # schedule.every(@poll_rate) { @sync_lock.synchronize { check_floorsense_log } }

    # between polls, sync the bookings
    schedule.in(@poll_rate / 2) do
      schedule.every(@poll_rate * 10) { sync_bookings }
      sync_bookings
    end
  end

  protected def log(&message : -> String)
    if @debug_logging
      logger.info { message.call }
    else
      logger.debug { message.call }
    end
  end

  # ===================================
  # Listening for events
  # ===================================
  private def booking_created(_subscription, event_info)
    event = NamedTuple(booking: BookingStatus?).from_json(event_info)
    booking = event[:booking]
    return unless booking
    return if booking.booking_type != "adhoc"

    floor_details = @floor_mappings[booking.planid.to_s]?
    return unless floor_details
    booking.user = User.from_json floorsense.get_user(booking.uid).get.to_json

    user_id = booking.user.not_nil!.desc
    user_email = booking.user.not_nil!.email.try &.downcase

    if user_id.presence.nil? && user_email.presence.nil?
      logger.warn { "no user id or email defined for floorsense user #{booking.user.not_nil!.name}" }
      return
    end

    user = begin
      staff_api.user(user_id.presence || user_email).get
    rescue error
      logger.warn(exception: error) { "floorsense user #{user_id.presence || user_email} (#{booking.user.not_nil!.name}) not found in placeos" }
      return
    end

    user_id = user["id"]
    user_name = user["name"]
    user_email = user["email"]

    log { "new floorsense booking found #{booking.inspect}" }

    # Check if there is a desk mapping
    booking_key = booking.key
    level_id = floor_details[:level_id]

    if metadata = @desk_mapping_cache[level_id][booking_key]?
      title = metadata.title
      ext_data = metadata.ext_data
      asset_id = metadata.place_id
    else
      title = asset_id = booking_key
      ext_data = {} of String => JSON::Any
    end
    ext_data["floorsense_booking_id"] = JSON::Any.new(booking.booking_id)

    staff_api.create_booking(
      booking_start: booking.start,
      booking_end: booking.finish,
      time_zone: @time_zone.to_s,
      booking_type: @booking_type,
      asset_id: asset_id,
      user_id: user_id,
      user_email: user_email,
      user_name: user_name,
      zones: [floor_details[:building_id]?, level_id].compact,
      checked_in: true,
      approved: true,
      title: title,
      extension_data: ext_data,
    ).get

    area_management.update_available([floor_details[:level_id]])
  end

  private def booking_released(_subscription, event_info)
    event = JSON.parse(event_info)
    booking = BookingStatus.from_json floorsense.get_booking(event["bkid"]).get.to_json
    floor_details = @floor_mappings[booking.planid.to_s]?
    return unless floor_details

    # ignore bookings that were cancelled outside of today
    return if booking.released >= booking.finish || booking.released <= booking.start

    # find placeos booking
    if place_booking = get_place_booking(booking, floor_details)
      # change the placeos end time if the booking has started
      staff_api.update_booking(
        booking_id: place_booking.id,
        booking_end: booking.released,
        checked_in: false
      ).get
    else
      logger.warn { "no booking found for released booking #{booking.booking_id}" }
    end

    area_management.update_available([floor_details[:level_id]])
  end

  private def booking_confirmed(_subscription, event_info)
    event = JSON.parse(event_info)
    booking = BookingStatus.from_json floorsense.get_booking(event["bkid"]).get.to_json
    floor_details = @floor_mappings[booking.planid.to_s]?
    return unless floor_details

    begin
      if desc = booking.desc
        place_booking = Booking.from_json staff_api.get_booking(desc.to_i64).get.to_json
        staff_api.booking_check_in(place_booking.id, booking.confirmed)

        area_management.update_available([floor_details[:level_id]])
      end
    rescue ArgumentError
      # was an adhoc booking
    end
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

    log { "parsing floorsense event log, #{events.size} new events" }

    @last_event_id = events.last.eventid
    events.each do |event|
      begin
        booking = BookingStatus.from_json floorsense.get_booking(event.bkid).get.to_json
        floor_details = @floor_mappings[booking.planid.to_s]?
        next unless floor_details

        case event.code
        when 49 # BOOKING_CREATE (ad-hoc?)
          next if booking.booking_type != "adhoc"

          user_id = booking.user.not_nil!.desc
          user_email = booking.user.not_nil!.email.try &.downcase

          if user_id.presence.nil? && user_email.presence.nil?
            logger.warn { "no user id or email defined for floorsense user #{booking.user.not_nil!.name}" }
            return
          end

          user = begin
            staff_api.user(user_id.presence || user_email).get
          rescue error
            logger.warn(exception: error) { "floorsense user #{user_id.presence || user_email} (#{booking.user.not_nil!.name}) not found in placeos" }
            return
          end

          user_id = user["id"]
          user_name = user["name"]
          user_email = user["email"]

          log { "new floorsense booking found #{booking}" }

          # Check if there is a desk mapping
          booking_key = booking.key
          level_id = floor_details[:level_id]

          if metadata = @desk_mapping_cache[level_id][booking_key]?
            title = metadata.title
            ext_data = metadata.ext_data
            asset_id = metadata.place_id
          else
            title = asset_id = booking_key
            ext_data = {} of String => JSON::Any
          end
          ext_data["floorsense_booking_id"] = JSON::Any.new(booking.booking_id)

          staff_api.create_booking(
            booking_start: booking.start,
            booking_end: booking.finish,
            time_zone: @time_zone.to_s,
            booking_type: @booking_type,
            asset_id: asset_id,
            user_id: user_id,
            user_email: user_email,
            user_name: user_name,
            zones: [floor_details[:building_id]?, level_id].compact,
            checked_in: true,
            approved: true,
            title: title,
            extension_data: ext_data,
          ).get
        when 50 # BOOKING_RELEASE (booking ended)
          # ignore bookings that were cancelled outside of today
          next if booking.released >= booking.finish || booking.released <= booking.start

          # find placeos booking
          if place_booking = get_place_booking(booking, floor_details)
            # change the placeos end time if the booking has started
            staff_api.update_booking(
              booking_id: place_booking.id,
              booking_end: booking.released,
              checked_in: false
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

    log { "booking event is in a matching zone" }

    sync_floor(matching_zones.first)
  end

  def sync_bookings
    @zone_mappings.keys.each { |zone_id| sync_floor(zone_id) }
  end

  def sync_floor(zone : String)
    @sync_lock.synchronize { do_sync_floor(zone) }
  end

  protected def do_sync_floor(zone : String)
    plan_id = @zone_mappings[zone]?
    if plan_id.nil?
      logger.warn { "unknown plan ID for zone #{zone}" }
      return 0
    end
    floor_details = @floor_mappings[plan_id]

    log { "syncing zone #{zone}, plan-id #{plan_id}" }

    place_bookings = placeos_bookings(zone)
    sense_bookings = floorsense_bookings(zone)

    # Apply desk mappings
    @desk_mapping_cache[zone] = configured_desk_ids = placeos_desk_metadata(zone, floor_details[:building_id])
    place_bookings.each do |booking|
      asset_id = booking.asset_id
      booking.floor_id = configured_desk_ids[asset_id]?.try(&.floor_id) || asset_id
    end
    sense_bookings.each do |booking|
      desk_key = booking.key
      booking.place_id = configured_desk_ids[desk_key]?.try(&.place_id) || desk_key
    end

    adhoc = [] of BookingStatus
    other = [] of BookingStatus

    sense_bookings.each do |booking|
      if booking.booking_type == "adhoc"
        adhoc << booking
      else
        other << booking
      end
    end

    log { "found #{adhoc.size} adhoc bookings" }

    place_booking_checked = Set(String).new
    release_floor_bookings = [] of BookingStatus
    release_place_bookings = [] of Tuple(Booking, Int64)
    create_place_bookings = [] of BookingStatus
    create_floor_bookings = [] of Booking
    confirm_floor_bookings = [] of BookingStatus

    time_now = 2.minutes.from_now.to_unix

    # adhoc bookings need to be added to PlaceOS
    adhoc.each do |floor_booking|
      found = false
      place_bookings.each do |booking|
        # match using extenstion data
        if (ext_data = booking.extension_data) && (floor_id = ext_data["floorsense_booking_id"]?.try(&.as_s)) && floor_id == floor_booking.booking_id
          found = true
          place_booking_checked << booking.id.to_s
        else
          next
        end

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          log { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          log { "releasing place booking #{booking.id}, as floor booking #{floor_booking.booking_id} has been released" }
          # need to change end time of this booking
          release_place_bookings << {booking, floor_booking.released}
        end

        break
      end

      if !found && floor_booking.released == 0_i64
        log { "found new ad-hoc booking #{floor_booking.booking_id}, will create place booking" }
        create_place_bookings << floor_booking
      end
    end

    log { "need to sync #{create_place_bookings.size} adhoc bookings, release #{release_place_bookings.size} bookings" }

    # what bookings need to be added to floorsense
    place_bookings.each do |booking|
      booking_id = booking.id.to_s
      next if place_booking_checked.includes?(booking_id)
      next if time_now >= booking.booking_end

      place_booking_checked << booking_id

      found = false
      other.each do |floor_booking|
        next unless floor_booking.desc == booking_id
        found = true

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          log { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          # need to change end time of this booking
          log { "releasing place booking #{booking.id}, as floor booking #{floor_booking.booking_id} has been released" }
          release_place_bookings << {booking, floor_booking.released}
        elsif booking.checked_in && !floor_booking.confirmed
          log { "confirming floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been confirmed" }
          confirm_floor_bookings << floor_booking
        end

        break
      end
      next if found || booking.rejected

      # if we get to here then the floor booking was released
      if (ext_data = booking.extension_data) && (floor_id = ext_data["floorsense_booking_id"]?.try(&.as_s))
        log { "releasing place booking #{booking.id}, as floor booking #{floor_id} not found (assuming released)" }
        release_place_bookings << {booking, 1.minute.ago.to_unix}
      else
        log { "creating floor booking based on #{booking.id} as no floor booking reference exists" }
        create_floor_bookings << booking
      end
    end

    other.each do |floor_booking|
      log { "releasing floor booking #{floor_booking.booking_id}, as place booking #{floor_booking.desc} not found (assuming deleted)" }
      release_floor_bookings << floor_booking unless place_booking_checked.includes?(floor_booking.desc)
    end

    log { "need to create #{create_floor_bookings.size} bookings, release #{release_floor_bookings.size} in floorsense" }

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

      resp = local_floorsense.create_booking(
        user_id: floor_user,
        plan_id: plan_id,
        key: booking.floor_id,
        description: booking.id.to_s,
        starting: booking.booking_start < time_now ? 5.minutes.ago.to_unix : booking.booking_start,
        ending: booking.booking_end
      )

      if booking.checked_in
        begin
          local_floorsense.confirm_booking(resp.get["bkid"])
        rescue error
          logger.warn(exception: error) { "error confirming newly created booking" }
        end
      end
    end

    log { "floorsense bookings created" }

    # update placeos
    local_staff_api = staff_api
    release_place_bookings.each do |booking, released|
      local_staff_api.update_booking(
        booking_id: booking.id,
        booking_end: released,
        checked_in: false
      )
    end

    log { "#{release_place_bookings.size} place bookings released" }

    create_place_bookings.each do |booking|
      user_id = booking.user.not_nil!.desc
      user_email = booking.user.not_nil!.email.try &.downcase

      if user_id.presence.nil? && user_email.presence.nil?
        logger.warn { "no user id or email defined for floorsense user #{booking.user.not_nil!.name}" }
        next
      end

      user = begin
        local_staff_api.user(user_id.presence || user_email).get
      rescue error
        logger.warn(exception: error) { "floorsense user #{user_email} not found in placeos" }
        next
      end
      user_id = user["id"]
      user_name = user["name"]
      user_email = user["email"]

      # Check if there is a desk mapping
      booking_key = booking.key
      level_id = floor_details[:level_id]

      if metadata = @desk_mapping_cache[level_id][booking_key]?
        title = metadata.title
        ext_data = metadata.ext_data
        asset_id = metadata.place_id
      else
        title = asset_id = booking.place_id
        ext_data = {} of String => JSON::Any
      end
      ext_data["floorsense_booking_id"] = JSON::Any.new(booking.booking_id)

      local_staff_api.create_booking(
        booking_start: booking.start,
        booking_end: booking.finish,
        time_zone: @time_zone.to_s,
        booking_type: @booking_type,
        asset_id: booking.place_id,
        user_id: user_id,
        user_email: user_email,
        user_name: user_name,
        checked_in: true,
        approved: true,
        title: title,
        zones: [floor_details[:building_id]?, level_id].compact,
        extension_data: ext_data,
      )
    end

    log { "#{create_place_bookings.size} adhoc place bookings created" }

    confirm_floor_bookings.each do |floor_booking|
      local_floorsense.confirm_booking(floor_booking.booking_id)
    end

    # number of bookings checked
    place_bookings.size + adhoc.size
  end

  def get_floorsense_user(place_user_id : String) : String
    place_user = staff_api.user(place_user_id).get
    placeos_staff_id = place_user[@user_lookup].as_s
    floorsense_users = floorsense.user_list(description: placeos_staff_id).get.as_a

    user_id = floorsense_users.first?.try(&.[]("uid").as_s)
    user_id ||= floorsense.create_user(place_user["name"].as_s, place_user["email"].as_s, placeos_staff_id).get["uid"].as_s if @create_floorsense_users
    raise "Floorsense user not found for #{placeos_staff_id}" unless user_id

    card_number = place_user["card_number"]?.try(&.as_s)
    spawn(same_thread: true) { ensure_card_synced(card_number, user_id) } if user_id && card_number && !card_number.empty?
    user_id
  end

  protected def ensure_card_synced(card_number : String, user_id : String) : Nil
    existing_user = begin
      floorsense.get_rfid(card_number).get["uid"].as_s
    rescue
      nil
    end

    if existing_user != user_id
      floorsense.delete_rfid(card_number)
      floorsense.create_rfid(user_id, card_number)
    end
  rescue error
    logger.warn(exception: error) { "failed to sync card number #{card_number} for user #{user_id}" }
  end

  def eui64_to_desk_id(id : String)
    if foor_id = locations.eui64_to_desk_id(id.downcase).get.raw
      floor_desk_id = foor_id.as(String)
      place_id = floor_desk_id
      level_id = nil
      building = nil

      @desk_mapping_cache.each do |level, lookup|
        if meta = lookup[floor_desk_id]?
          level_id = level
          place_id = meta.place_id || floor_desk_id
          building = meta.building
          break
        end
      end

      {level: level_id, desk_id: place_id, building_id: building} if level_id
    end
  end

  # ===================================
  # Booking Queries
  # ===================================
  def floorsense_bookings(zone_id : String)
    log { "querying floorsense bookings in zone #{zone_id}" }

    plan_id = @zone_mappings[zone_id]?
    return [] of BookingStatus unless plan_id

    current = [] of BookingStatus
    start_of_day = Time.local(@time_zone).at_beginning_of_day
    tomorrow_night = (start_of_day.at_end_of_day + 1.hour).at_end_of_day - 1.minute

    raw_bookings = floorsense.bookings(plan_id, start_of_day.to_unix, tomorrow_night.to_unix).get.to_json
    Hash(String, Array(BookingStatus)).from_json(raw_bookings).each_value do |bookings|
      current.concat bookings
    end
    current
  end

  def placeos_bookings(zone_id : String)
    start_of_day = Time.local(@time_zone).at_beginning_of_day
    tomorrow_night = (start_of_day.at_end_of_day + 1.hour).at_end_of_day - 1.minute

    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: start_of_day.to_unix,
      period_end: tomorrow_night.to_unix,
      zones: {zone_id}
    ).get.as_a

    bookings.map { |book| Booking.from_json(book.to_json) }
  end

  def placeos_desk_metadata(zone_id : String, building_id : String?)
    desk_lookup = {} of String => DeskMeta

    begin
      metadata = staff_api.metadata(
        zone_id,
        "desks"
      ).get["desks"]["details"].as_a

      lookup_key = @floorsense_lookup_key
      metadata.each do |desk|
        desk = desk.as_h
        place_id = desk["id"]?.try(&.as_s.presence)
        next unless place_id

        floor_id = desk[lookup_key]?.try(&.as_s.presence)
        next unless floor_id

        # Additional data for adhoc bookings
        ext_data = {
          "floorsense_id" => JSON::Any.new(floor_id),
        }
        title = desk["name"]?.try(&.as_s) || place_id
        @meta_ext_mappings.each do |meta_key, ext_key|
          if value = desk[meta_key]?
            ext_data[ext_key] = value
          end
        end

        ids = DeskMeta.new(place_id, floor_id, building_id, title, ext_data)
        desk_lookup[place_id] = ids
        desk_lookup[floor_id] = ids
      end
      desk_lookup
    rescue error
      logger.warn(exception: error) { "unable to obtain desk metadata for #{zone_id}" }
      desk_lookup
    end
  end

  struct DeskMeta
    include JSON::Serializable

    def initialize(@place_id, @floor_id, @building, @title, @ext_data)
    end

    property place_id : String
    property floor_id : String
    property building : String?
    getter ext_data : Hash(String, JSON::Any)
    getter title : String
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

    @[JSON::Field(ignore: true)]
    property! floor_id : String

    def in_progress?
      now = Time.utc.to_unix
      now >= @booking_start && now < @booking_end
    end
  end
end
