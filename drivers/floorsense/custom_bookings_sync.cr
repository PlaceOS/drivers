require "placeos-driver"
require "placeos-driver/interface/locatable"
require "uri"
require "json"
require "oauth2"
require "./models"
require "placeos"

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

  alias PlaceUser = PlaceOS::Client::API::Models::User

  DESK_SOURCE_EXTENSION_DATA_MODIFICATION   = "floorsense"
  LOCKER_SOURCE_EXTENSION_DATA_MODIFICATION = "smartalock"

  default_settings({
    floor_mappings: {
      "planid": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
    time_zone:   "GMT",
    poll_rate:   3,
    user_lookup: "email",

    floorsense_lookup_key:   "floorsense_id",
    create_floorsense_users: true,
    booking_type:            "desk",
    # Keys to map into ad-hoc bookings
    meta_ext_mappings: {
      "neighbourhoodID" => "neighbourhood",
      "features"        => "deskAttributes",
    },
    meta_ext_static: {} of String => String,
  })

  @sync_locker_lock = Mutex.new
  @mutex_event_desk = Mutex.new
  @user_ids_cache : Hash(String, String) = {} of String => String
  @meta_ext_static : Hash(String, String) = {} of String => String

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
  @poll_rate : Time::Span = 3.seconds
  @time_zone : Time::Location = Time::Location.load("GMT")
  @user_lookup : String = "email"

  # ===================================
  # Polling for events
  # ===================================
  @last_event_id : Int64? = nil
  @last_event_at : Int64 = 0_i64

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      unless (@zone_mappings.keys & Booking.from_json(payload).zones).empty?
        booking_changed(Booking.from_json(payload))
      end
    end

    on_update
  end

  def on_update
    @booking_type = setting?(String, :booking_type).presence || "desk"

    @poll_rate = (setting?(Int32, :poll_rate) || 3).seconds
    @user_lookup = setting?(String, :user_lookup).presence || "email"

    @floorsense_lookup_key = setting?(String, :floorsense_lookup_key).presence || "floorsensedeskid"
    @create_floorsense_users = setting?(Bool, :create_floorsense_users) || false

    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @floor_mappings.each do |plan_id, details|
      level = details[:level_id]
      @building_mappings[level] = details[:building_id]
      @zone_mappings[level] = plan_id
    end

    @meta_ext_mappings = setting?(Hash(String, String), :meta_ext_mappings) || {} of String => String
    @meta_ext_static = setting?(Hash(String, String), :meta_ext_static) || {} of String => String

    time_zone = setting?(String, :time_zone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    schedule.clear

    schedule.every(@poll_rate * 10) { sync_bookings }
    schedule.in(1.seconds) { sync_bookings }
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
  protected def booking_changed(booking)
    return unless booking.booking_type == "desk"
    matching_zones = @zone_mappings.keys & booking.zones
    if matching_zones.empty?
      logger.debug { "No matching zone for #{booking.id}, zones=#{booking.zones}" }
      return
    end

    logger.debug { "Payload: #{booking.inspect} EventSync: #{booking.id}" }

    if booking.action == "checked_in" && (ext_data = booking.extension_data) && (floorsense_id = ext_data["floorsense_booking_id"]?)
      if (booking.checked_in == true)
        begin
          logger.debug { "Attempting fast check-in for #{booking.id}" }
          activate_booking = booking.booking_start > Time.utc.to_unix
          confirm_check_in_floorsense(booking.id, floorsense_id, activate: activate_booking, confirm: true)
        rescue error
          logger.warn(exception: error) { "attempting fast check-in" }
        end
      else
        begin
          logger.debug { "Attempting fast check-out for #{booking.id}" }
          checkout_or_cancel_floorsense(booking.id, floorsense_id, "check_out_floorsens")
        rescue error
          logger.warn(exception: error) { "attempting fast check-out" }
        end
      end
    elsif booking.action == "cancelled" && (ext_data = booking.extension_data) && (floorsense_id = ext_data["floorsense_booking_id"]?)
      begin
        logger.debug { "Attempting fast cancel for #{booking.id}" }
        checkout_or_cancel_floorsense(booking.id, floorsense_id, "cancel_floorsens")
      rescue error
        logger.warn(exception: error) { "attempting fast cancel" }
      end
    else
      logger.debug { "Skipped fast check-in for #{booking.id}" }
    end

    sync_floor(matching_zones.first)
  end

  def sync_bookings
    @zone_mappings.keys.each { |zone_id| sync_floor(zone_id) }
  end

  getter sync_busy : Hash(String, Bool) = Hash(String, Bool).new { |hash, key| hash[key] = false }
  getter sync_queue : Hash(String, Int32) = Hash(String, Int32).new { |hash, key| hash[key] = 0 }
  getter sync_times : Hash(String, Array(Float64)) = Hash(String, Array(Float64)).new { |hash, key| hash[key] = [] of Float64 }

  def sync_floor(zone : String)
    @sync_queue[zone] += 1
    if !@sync_busy[zone]
      spawn { queue_sync_floor(zone) }
      Fiber.yield
      :syncing
    else
      :queued
    end
  end

  # this effectively batches requests if they come in quickly
  protected def queue_sync_floor(zone : String)
    # ensure we're not already syncing
    return if @sync_busy[zone]
    @sync_busy[zone] = true

    begin
      times = sync_times[zone]
      loop do
        elapsed_time = Time.measure do
          begin
            @sync_queue[zone] = 0
            unique_id = Random::Secure.hex(10)
            do_sync_floor(zone, unique_id)
          rescue error
            logger.warn(exception: error) { "syncing #{zone}" }
          end
        end
        total_milliseconds = elapsed_time.total_milliseconds
        times << total_milliseconds
        times.shift if times.size > 15

        logger.info { "sync_floor zone: #{zone} duration=#{total_milliseconds}" }

        break if @sync_queue[zone].zero?
        Fiber.yield
      end
    rescue error
      logger.warn(exception: error) { "error syncing floor: #{zone}" }
    ensure
      @sync_busy[zone] = false
    end
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
      zones: {zone_id},
      include_checked_out: true,
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

  # ===================================
  # Monitoring desk bookings
  # ===================================

  protected def do_sync_floor(zone : String, unique_id : String)
    plan_id = @zone_mappings[zone]?
    if plan_id.nil?
      logger.warn { "unknown plan ID for zone #{zone}" }
      return 0
    end
    floor_details = @floor_mappings[plan_id]

    logger.debug { "syncing floor zone #{zone}, plan-id #{plan_id}" }

    place_bookings = placeos_bookings(zone)
    sense_bookings = floorsense_bookings(zone)

    # Apply desk mappings
    @desk_mapping_cache[zone] = configured_desk_ids = placeos_desk_metadata(zone, floor_details[:building_id])
    place_bookings.each do |booking|
      asset_id = booking.asset_id
      booking.floor_id = configured_desk_ids[asset_id]?.try(&.floor_id) || asset_id
    end
    sense_bookings.select! do |booking|
      desk_key = booking.key.as(String)
      if place_id = configured_desk_ids[desk_key]?.try(&.place_id)
        booking.place_id = place_id
      else
        logger.debug { "unmapped floorsense desk id #{desk_key} in floor zone #{zone}, plan-id #{plan_id}" }
        nil
      end
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

    logger.debug { "found #{adhoc.size} adhoc bookings" }

    place_booking_checked = Set(String).new
    release_floor_bookings = [] of BookingStatus
    release_place_bookings = [] of Tuple(Booking, Int64)
    create_place_bookings = [] of BookingStatus
    create_floor_bookings = [] of Booking
    confirm_floor_bookings = [] of BookingStatus
    sync_place_metadata = [] of Tuple(String, String, Int32)

    time_now = 2.minutes.from_now.to_unix

    # adhoc bookings need to be added to PlaceOS
    adhoc.each do |floor_booking|
      found = false
      place_bookings.each do |booking|
        # match using extenstion data
        if booking.floorsense_booking_id == floor_booking.booking_id
          found = true
          place_booking_checked << booking.id.to_s
        else
          next
        end

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif booking.released? && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif booking.is_deleted? && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been deleted" }
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          logger.debug { "releasing place booking #{booking.id}, as floor booking #{floor_booking.booking_id} has been released" }
          # need to change end time of this booking
          release_place_bookings << {booking, floor_booking.released}
        end

        break
      end

      if !found && floor_booking.released == 0_i64
        logger.debug { "found new ad-hoc booking #{floor_booking.booking_id}, will create place booking" }
        create_place_bookings << floor_booking
      end
    end

    logger.debug { "need to sync #{create_place_bookings.size} adhoc bookings, release #{release_place_bookings.size} bookings" }

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

        sync_place_metadata << {booking_id, floor_booking.booking_id, floor_booking.cid} unless booking.floorsense_booking_id == floor_booking.booking_id
        logger.debug { "sync_place_metadata-floor_booking_booking_id: #{floor_booking.booking_id} booking_id:#{booking_id} floor_booking_desc: #{floor_booking.desc} booking.floorsense_booking_id: #{booking.floorsense_booking_id}" }

        if (booking.rejected || booking.booking_end != floor_booking.finish) && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif booking.released? && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been released" }
          release_floor_bookings << floor_booking
        elsif booking.is_deleted? && floor_booking.released == 0_i64
          logger.debug { "releasing floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been deleted" }
          release_floor_bookings << floor_booking
        elsif floor_booking.released > 0_i64 && floor_booking.released != booking.booking_end && !booking.rejected
          # need to change end time of this booking
          logger.debug { "releasing place booking #{booking.id}, as floor booking #{floor_booking.booking_id} has been released" }
          release_place_bookings << {booking, floor_booking.released}
        elsif booking.checked_in && !floor_booking.confirmed
          logger.debug { "confirming floor booking #{floor_booking.booking_id}, as place booking #{booking.id} has been confirmed" }
          confirm_floor_bookings << floor_booking
        end

        break
      end
      next if found || booking.rejected

      # if we get to here then the floor booking was released
      if booking.floorsense_booking_id.nil? && !booking.released? && !booking.is_deleted?
        logger.debug { "creating floor booking based on #{booking.id} as no floor booking reference exists" }
        create_floor_bookings << booking
      elsif !booking.released? && !booking.is_deleted?
        logger.debug { "releasing place booking #{booking.id}, as floor booking #{booking.floorsense_booking_id} not found (assuming released)" }
        release_place_bookings << {booking, 1.minute.ago.to_unix}
      end
    end

    other.each do |floor_booking|
      unless place_booking_checked.includes?(floor_booking.desc)
        logger.debug { "releasing floor booking #{floor_booking.booking_id}, as no place booking found" }
        release_floor_bookings << floor_booking
      end
    end

    logger.debug { "need to create #{create_floor_bookings.size} bookings, release #{release_floor_bookings.size} in floorsense" }

    # update floorsense
    local_floorsense = floorsense
    release_floor_bookings.each { |floor_booking| local_floorsense.release_booking(floor_booking.booking_id) }

    create_floor_bookings.each do |booking|
      # info("#{booking.id} #{booking.floor_id} #{booking.asset_id}", event_name)
      # if booking.floor_id.to_s == booking.asset_id.to_s
      #   info("#{booking.id} has no floor id, skipping", "#{event_name} - booking_id #{booking.id}")
      #   next
      # end
      floor_user = begin
        get_floorsense_user(booking.user_id)
      rescue error
        logger.warn(exception: error) { "unable to find or create user #{booking.user_id} (#{booking.user_email}) in floorsense" }
        next
      end

      # We need a floorsense user to own the booking
      # floor_user = local_floorsense.user_list(booking.user_email).get.as_a.first?
      begin
        create_floorsense_booking(floor_user, plan_id, booking, time_now, local_floorsense)
      rescue error
        logger.warn(exception: error) { "unable to create_floorsense_booking #{booking.user_id} booking_id: #{booking.user_id} (#{booking.user_email}) in floorsense" }
        next
      end
    end

    logger.debug { "End creating floorsense bookings" }

    # update placeos
    local_staff_api = staff_api
    release_place_bookings.each do |booking, released|
      if booking.checked_in_at
        logger.debug { "Booking #{booking.id}: running check in" }
        staff_api.booking_check_in(booking.id, false, utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION).get
      else
        logger.debug { "Booking #{booking.id}: will be no show" }
        staff_api.update_booking(
          booking_id: booking.id,
          booking_end: released
        ).get
      end
    end

    logger.debug { "#{release_place_bookings.size} place bookings released" }

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
      else
        title = booking.place_id
        ext_data = {} of String => JSON::Any
      end
      ext_data["floorsense_booking_id"] = JSON::Any.new(booking.booking_id)
      ext_data["floorsense_cid"] = JSON::Any.new(booking.cid.to_i64)

      begin
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
          utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION
        ).get
      rescue error
        logger.warn(exception: error) { "unable to create booking #{booking.to_json}" }
      end
    end

    logger.debug { "#{create_place_bookings.size} adhoc place bookings created" }

    confirm_floor_bookings.each do |floor_booking|
      confirm_check_in_floorsense(floor_booking.desc, floor_booking.booking_id, activate: !floor_booking.active, local_floorsense: local_floorsense)
    end

    logger.debug { "#{sync_place_metadata.size} place booking metadata sync'd" }
    sync_place_metadata.each { |p_id, f_id, c_id| sync_place_booking_metadata(p_id, f_id, c_id) }

    # number of bookings checked
    place_bookings.size + adhoc.size
  end

  private def create_floorsense_booking(floor_user, plan_id, booking, time_now, local_floorsense)
    start = Time.monotonic
    resp = local_floorsense.create_booking(
      user_id: floor_user,
      plan_id: plan_id,
      key: booking.floor_id,
      description: booking.id.to_s,
      starting: booking.booking_start < time_now ? 5.minutes.ago.to_unix : booking.booking_start,
      ending: booking.booking_end
    ).get

    elapsed = Time.monotonic - start
    logger.debug { "floorsense Booking creation: create_floorsense_booking create_booking duration=#{elapsed.total_milliseconds} for booking-id: #{booking.id}" }

    if booking.checked_in
      confirm_check_in_floorsense(booking.id, resp["bkid"], activate: !resp["active"].as_bool, confirm: !resp["confirmed"].as_bool, local_floorsense: local_floorsense)
    end

    # ensure floorsense_booking_id and cid is set on the place booking
    sync_place_booking_metadata(booking.id, resp["bkid"], resp["cid"])
  rescue error
    logger.warn(exception: error) { "Error creating floor_user:#{floor_user} booking-id:#{booking.id} response: #{resp}" }
  end

  protected def sync_place_booking_metadata(place_booking_id, floorsense_booking_id, floorsense_cid)
    logger.debug { "sync_place_metadata place_booking_id: #{place_booking_id} floorsense_booking_id:#{floorsense_booking_id} floorsense_cid:#{floorsense_cid}" }
    staff_api.update_booking(
      booking_id: place_booking_id,
      extension_data: {
        floorsense_cid:        floorsense_cid,
        floorsense_booking_id: floorsense_booking_id,
      }
    )
  end

  protected def confirm_check_in_floorsense(place_booking_id, floor_booking_id, activate : Bool = true, confirm : Bool = true, event_name = "check_in_floorsense", local_floorsense = floorsense)
    if activate
      begin
        local_floorsense.activate_booking(floor_booking_id)
        logger.debug { "activate_booking booking-id: #{place_booking_id}" }
      rescue error
        logger.warn(exception: error) { "error activating newly created booking booking-id: #{place_booking_id}" }
      end
    end

    if confirm
      begin
        local_floorsense.confirm_booking(floor_booking_id)
        logger.debug { "confirm_booking booking-id: #{place_booking_id}" }
      rescue error
        logger.warn(exception: error) { "error confirming newly created booking booking-id: #{place_booking_id}" }
      end
    end
  end

  protected def checkout_or_cancel_floorsense(place_booking_id, floor_booking_id, event_name, local_floorsense = floorsense)
    begin
      local_floorsense.release_booking(floor_booking_id)
      logger.debug { "#{event_name} booking booking-id: #{place_booking_id}" }
    rescue error
      logger.warn(exception: error) { "error #{event_name} booking booking-id: #{place_booking_id}" }
    end
  end

  def get_floorsense_user(place_user_id : String) : String
    place_user = staff_api.user(place_user_id).get
    placeos_staff_id = place_user[@user_lookup].as_s

    if @user_lookup == "email"
      placeos_staff_id = placeos_staff_id.downcase
      floorsense_users = floorsense.user_list(email: placeos_staff_id).get.as_a

      user_id = floorsense_users.first?.try(&.[]("uid").as_s)
      user_id ||= floorsense.create_user(place_user["name"].as_s, placeos_staff_id).get["uid"].as_s if @create_floorsense_users
    else
      floorsense_users = floorsense.user_list(description: placeos_staff_id).get.as_a

      user_id = floorsense_users.first?.try(&.[]("uid").as_s)
      user_id ||= floorsense.create_user(place_user["name"].as_s, place_user["email"].as_s, placeos_staff_id).get["uid"].as_s if @create_floorsense_users
    end
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
    else
      logger.warn { "No desk found for #{id}" }
    end
  end

  private def sync_placeos_booking?(reservation, synced_place_locker_bookings)
    synced_place_locker_bookings.find { |p| p.smartalock_res_id == reservation.reservation_id }
  end

  private def booking_created(_subscription, event_info)
    logger.debug { "Booking created event: #{event_info.to_json}" }

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
    ext_data["floorsense_cid"] = JSON::Any.new(booking.cid.to_i64)

    logger.debug { "floorsense booking id: #{booking.booking_id} in Booking created event" }

    placebookings = staff_api.query_bookings(
      type: @booking_type,
      zones: {level_id},
      extension_data: {floorsense_booking_id: booking.booking_id}
    ).get.as_a

    return unless placebookings.empty?

    body = staff_api.create_booking(
      booking_start: booking.start,
      booking_end: booking.finish,
      booking_type: @booking_type,
      asset_id: asset_id,
      user_id: user_id,
      user_email: user_email,
      user_name: user_name,
      time_zone: @time_zone.to_s,
      zones: [floor_details[:building_id]?, level_id].compact,
      approved: true,
      title: title,
      extension_data: ext_data,
      utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION,
    ).get

    logger.debug { "placeos booking created #{body["id"]}" }

    placeos_booking = Booking.from_json(body.to_json)
    logger.debug { "placeos user LOAD #{placeos_booking.id}" }

    staff_api.booking_check_in(placeos_booking.id, true, utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION).get
    logger.debug { "placeos booking checked in #{placeos_booking.id}" }

    area_management.update_available([floor_details[:level_id]])
  rescue error
    logger.warn(exception: error) { "Something went wrong processing floorsense booking created event" }
  end

  private def booking_confirmed(_subscription, event_info)
    event = JSON.parse(event_info)
    logger.debug { "Booking confirmed event: #{event}" }
    booking = BookingStatus.from_json floorsense.get_booking(event["bkid"]).get.to_json
    logger.debug { "Floor_Booking: #{booking}" }
    floor_details = @floor_mappings[booking.planid.to_s]?
    logger.debug { "floor_details: #{floor_details}" }
    return unless floor_details

    begin
      if desc = booking.desc
        place_booking = Booking.from_json staff_api.get_booking(desc.to_i64).get.to_json
        logger.debug { "place_booking: #{place_booking}" }
        staff_api.booking_check_in(place_booking.id, booking.confirmed, utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION) unless place_booking.checked_in?

        area_management.update_available([floor_details[:level_id]])
      end
    rescue ArgumentError
      # was an adhoc booking
    end
  end

  private def booking_released(_subscription, event_info)
    logger.debug { "Booking released event: #{event_info.to_json}" }
    event = JSON.parse(event_info)
    booking = BookingStatus.from_json floorsense.get_booking(event["bkid"]).get.to_json
    floor_details = @floor_mappings[booking.planid.to_s]?
    unless floor_details
      logger.warn { "No floor details found for planid #{booking.planid}" }
      return
    end

    # No booking confirm, means floorsense canceled which hasn't been check in on PlaceOS
    # we ignore this scenario because you can cancel before booking is confirmed.
    if !booking.confirmed && (booking.released >= booking.finish || booking.released <= booking.start)
      logger.debug { "Booking was released outside of booking time, ignoring #{booking.to_json}" }
      return
    end

    # find placeos booking
    place_booking = get_strict_place_booking(booking, floor_details)

    if place_booking.nil?
      logger.debug { "no booking found for released booking #{booking.booking_id}" }
    elsif !place_booking.is_deleted? && !place_booking.released?
      # change the placeos end time if the booking has started
      logger.debug { "Booking #{place_booking.id}: updating placeos end time to #{booking.released}, #{place_booking.checked_in_at}" }
      if place_booking.checked_in_at
        logger.debug { "Booking #{place_booking.id}: running check in" }
        staff_api.booking_check_in(place_booking.id, false, utm_source: DESK_SOURCE_EXTENSION_DATA_MODIFICATION).get
      else
        logger.debug { "Booking #{place_booking.id}: will be no show" }
        staff_api.update_booking(
          booking_id: place_booking.id,
          booking_end: booking.released
        ).get
      end
    else
      logger.debug { "Booking exists but already deleted #{place_booking.is_deleted?} or checkout #{place_booking.released?}" }
    end

    area_management.update_available([floor_details[:level_id]])
  end

  protected def get_strict_place_booking(floorsense_booking, floor_details) : Booking?
    desc = floorsense_booking.desc
    if desc.nil?
      search_booking_by_floorsense_id(floorsense_booking, floor_details)
    else
      Booking.from_json staff_api.get_booking(desc.to_i64).get.to_json
    end
  rescue ArgumentError
    # in case the description was unexpectedly not an int64 (adhoc for instance)
    search_booking_by_floorsense_id(floorsense_booking, floor_details)
  rescue error
    logger.warn(exception: error) { "error getting place booking" }
    raise error
  end

  protected def search_booking_by_floorsense_id(freespace_booking, floor_details)
    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: freespace_booking.start,
      zones: {floor_details[:level_id]},
      extension_data: {floorsense_booking_id: freespace_booking.booking_id}
    ).get.as_a

    logger.debug { "booking on search_booking_by_floorsense_id size #{bookings.size}" }

    b1 = bookings.map { |book|
      booking = Booking.from_json(book.to_json)
      booking.rejected ? nil : booking
    }

    b2 = b1.compact
    b3 = b2.first?

    logger.debug { "booking to be return #{b3.to_json}" }
    b3
  rescue error
    logger.warn(exception: error) { "searching for floorsense id" }
    raise error
  end

  private def get_user(floorsense_user_id)
    placeos_user_id = @user_ids_cache[floorsense_user_id]?
    if placeos_user_id.nil?
      floorsense_user = floorsense.get_user(floorsense_user_id).get
      user = staff_api.user(floorsense_user["desc"].as_s).get
      @user_ids_cache[floorsense_user_id] = user["id"].as_s
    else
      user = staff_api.user(placeos_user_id).get
    end
    PlaceUser.from_json(user.to_json)
  rescue error
    logger.warn(exception: error) { "User not found in Placeos : #{floorsense_user_id}" }
    return
  end

  # Forcing recompilation with latest changes on extension data
  private def fetch_desk(desk_id)
    desk_api.fetch_desk(desk_id).get["payload"]
  rescue error
    logger.warn(exception: error) { "desk #{desk_id} not found" }
    raise "Desk not found"
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

        @meta_ext_static.each do |key, value|
          ext_data[key] = JSON::Any.new(value)
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
end
