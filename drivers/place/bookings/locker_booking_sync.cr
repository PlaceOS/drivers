require "placeos-driver"
require "placeos-driver/interface/lockers"
require "../booking_model"
require "./locker_models"

# makes the assumption that there are no future bookings,
# you can only book a locker now if it's currently free.
class Place::Bookings::LockerBookingSync < PlaceOS::Driver
  include Place::LockerMetadataParser

  descriptive_name "PlaceOS Locker Booking Sync"
  generic_name :LockerBookingSync
  description "Syncs placeos bookings with a physical lockers system via the placeos locker interface"

  default_settings({
    authority_id: "auth-1234",
  })

  # synced == allocation_id in placeos booking.process_state
  alias PlaceLocker = PlaceOS::Driver::Interface::Lockers::PlaceLocker
  alias LockerMetadata = Place::Locker

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  def locker_locations
    system.implementing(Interface::Lockers)
  end

  def on_load
    schedule.every(10.minutes) { ensure_locker_access }
    on_update
  end

  def on_update
    @building_id = nil
    @timezone = nil
    @systems = nil
    @locker_banks = nil
    @locker_details = nil

    authority_id = setting(String, :authority_id)
    subscriptions.clear
    monitor("#{authority_id}/staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      check_allocation(Booking.from_json payload)
    end
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  # Grabs the list of systems in the building
  getter systems : Hash(String, Array(String)) do
    staff_api.systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  end

  def levels : Array(String)
    systems.keys
  end

  # system or building timezone
  protected getter timezone : Time::Location do
    tz = config.control_system.try(&.timezone) || staff_api.zone(building_id).get["timezone"].as_s
    Time::Location.load(tz)
  end

  # locker_banks included from LockerMetadataParser

  # ===========================
  # Primary Locker booking sync
  # ===========================

  @mutex = Mutex.new
  @sync_busy : Hash(String, Bool) = Hash(String, Bool).new { |hash, key| hash[key] = false }
  @sync_queue : Hash(String, Int32) = Hash(String, Int32).new { |hash, key| hash[key] = 0 }

  def ensure_locker_access
    levels.each { |zone_id| sync_level zone_id }
  end

  def sync_level(zone : String) : Nil
    @mutex.synchronize do
      @sync_queue[zone] += 1
      if !@sync_busy[zone]
        spawn { queue_sync_level(zone) }
        :syncing
      else
        :queued
      end
    end
  end

  protected def queue_sync_level(zone : String) : Nil
    # ensure we're not already syncing
    @mutex.synchronize do
      return if @sync_busy[zone]
      @sync_busy[zone] = true
    end

    begin
      loop do
        begin
          @mutex.synchronize { @sync_queue[zone] = 0 }
          unique_id = Random::Secure.hex(10)
          do_sync_level(zone, unique_id)
        rescue error
          logger.warn(exception: error) { "syncing #{zone}" }
        end

        break if @mutex.synchronize { @sync_queue[zone].zero? }
        Fiber.yield
      end
    rescue error
      logger.warn(exception: error) { "error syncing floor: #{zone}" }
    ensure
      @mutex.synchronize { @sync_busy[zone] = false }
    end
  end

  protected def do_sync_level(level_id : String, unique_id : String) : Nil
    # grab placeos bookings (now to 1 hour from now, including deleted / checked out)
    starting = Time.local(timezone)
    end_of_day = starting.at_end_of_day
    place_bookings_raw = staff_api.query_bookings(starting.to_unix, end_of_day.to_unix, zones: {level_id}, type: "locker", include_checked_out: true).get.as_a
    place_bookings_raw.concat staff_api.query_bookings(starting.to_unix, end_of_day.to_unix, zones: {level_id}, type: "locker", deleted: true).get.as_a
    place_bookings = Array(Booking).from_json place_bookings_raw.to_json
    place_bookings_raw.clear

    # remove older instances of the recurring booking
    place_bookings.sort! { |a, b| a.booking_start <=> b.booking_start }.uniq! { |book| book.id }

    logger.debug { "found #{place_bookings.size} place bookings -- id:#{unique_id}" }

    # grab current locker allocations
    locker_systems = locker_locations
    lockers = locker_systems.flat_map do |locker_system|
      Array(PlaceLocker).from_json locker_system.device_locations(level_id).get.to_json
    end

    logger.debug { "found #{lockers.size} locker allocations -- id:#{unique_id}" }

    # match bookings with the allocations
    allocate_lockers = [] of Booking
    release_lockers = [] of Booking
    place_bookings.reject! do |booking|
      if booking.deleted || booking.rejected || !booking.checked_out_at.nil?
        release_lockers << booking
      elsif booking.process_state.presence.nil?
        allocate_lockers << booking
      end
    end

    # remove allocations where a place booking has been checked out
    # ensure the locker is still allocated to that user
    release_lockers.each do |place_booking|
      allocation_id = place_booking.process_state
      next unless allocation_id

      if locker = lockers.find { |lock| lock.allocation_id == allocation_id }
        locker_systems.locker_release(locker.bank_id, locker.locker_id, place_booking.user_id.presence || place_booking.user_email) rescue nil
        lockers.delete locker
      end
    end

    logger.debug { "released #{release_lockers.size} lockers -- id:#{unique_id}" }

    # allocate lockers where a place booking has been created
    allocated = 0
    skipped = 0
    alloc_failed = [] of Booking
    allocate_lockers.each do |place_booking|
      asset_id = place_booking.asset_id
      place_user_id = place_booking.user_id.presence || place_booking.user_email

      locker_meta = locker_details[asset_id]?
      if locker_meta.nil?
        skipped += 1
        logger.warn { "unable to find locker details for locker id: #{asset_id}" }
        next
      end

      locker = locker_systems.compact_map do |locker_system|
        if json = (locker_system.locker_allocate(place_user_id, locker_meta.bank_id, locker_meta.id).get rescue nil)
          PlaceLocker.from_json json.to_json
        end
      end.first?

      # check if the locker is allocated to the current user (booking_state update may have failed earlier)
      if locker.nil? && (found = lockers.find { |lock| lock.locker_id == asset_id })
        locker = locker_systems.flat_map { |locker_system|
          Array(PlaceLocker).from_json locker_system.lockers_allocated_to(place_user_id).get.to_json
        }.select! { |lock| lock.locker_id == asset_id }.first?

        lockers.delete(found) if locker
      end

      # store the allocation id in placeos, if locker allocate failed then we'll hopefully
      # resolve this below if this step failed in a previous run
      if locker
        staff_api.booking_state(place_booking.id, locker.allocation_id)
        allocated += 1
      else
        alloc_failed << place_booking
      end
    end

    logger.debug { "allocated #{allocated} lockers, failed #{alloc_failed.size}, skipped #{skipped} -- id:#{unique_id}" }

    # checkout placeos bookings where a locker has been released
    # or there is a clash (locker allocated to someone else already)
    checked_out = 0
    place_bookings.each do |booking|
      allocation_id = booking.process_state
      if locker = lockers.find { |lock| lock.allocation_id == allocation_id }
        # we found the locker so we don't need to create a placeos booking
        lockers.delete(locker)
      else
        checked_out += 1
        # locker has been released so we should free the booking
        staff_api.update_booking(booking.id, checked_in: false, recurrence_end: booking.booking_end)
        staff_api.update_booking(booking.id, checked_in: false, instance: booking.instance) if booking.instance
      end
    end

    logger.debug { "ended #{checked_out} placeos locker bookings -- id:#{unique_id}" }

    # create placeos bookings where a locker has been allocated
    start_of_day = starting.at_beginning_of_day
    end_of_week = starting.at_end_of_week
    allocated = 0
    skipped = 0
    lockers.each do |lock|
      owner = locker_systems.check_ownership_of(lock.mac).get.first?
      email = owner["email"]?.try(&.as_s?).presence if owner
      if email.nil?
        logger.warn { "unable to find locker mac #{lock.mac} -- id:#{unique_id}" }
        skipped += 1
        next
      end

      user = staff_api.user(email).get
      staff_api.create_booking(
        booking_type: "locker",
        asset_id: lock.locker_id,
        user_id: user["id"],
        user_email: email,
        user_name: user["name"],
        zones: [level_id] + config.control_system.not_nil!.zones,
        booking_start: start_of_day.to_unix,
        booking_end: end_of_day.to_unix,
        checked_in: true,
        title: lock.locker_name,
        process_state: lock.allocation_id,
        recurrence_type: "DAILY",
        recurrence_end: end_of_week.to_unix,
      )
      allocated += 1
    rescue error
      logger.warn(exception: error) { "error c locker mac #{lock.mac} -- id:#{unique_id}" }
      skipped += 1
    end

    logger.debug { "created #{allocated} placeos locker bookings. Failed to find #{skipped} users -- id:#{unique_id}" }
  end

  # ===========================
  # Booking change notification
  # ===========================

  protected def check_allocation(booking : Booking)
    return unless booking.booking_type == "locker"
    if zone = (booking.zones & levels).first?
      queue_sync_level(zone)
    end
  end
end
