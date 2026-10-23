require "placeos-driver"
require "./booking_model"

class Place::BookingApprover < PlaceOS::Driver
  descriptive_name "Booking Auto Approver"
  generic_name :BookingApprover
  description %(Automatically approves all PlaceOS bookings, optionally rejecting bookings for assets not defined in zone metadata)

  accessor staff_api : StaffAPI_1

  default_settings({
    approve_booking_types: ["desk"],
    approve_zones:         ["zone-12345"],

    # reject bookings for assets that are not defined in the building level zone metadata
    reject_undefined_assets:    false,
    bookable_assets_cache_cron: "0 0 * * *",
    # time_zone: "Australia/Sydney",

    # booking_type => zone metadata key
    asset_metadata_keys: {
      "desk"    => "desks",
      "parking" => "parking-spaces",
    },
  })

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      approve_booking(Booking.from_json payload)
    end
    on_update
  end

  @bookings_approved : Int32 = 0
  @bookings_rejected : Int32 = 0
  @approve_zones : Array(String) = [] of String
  @approve_booking_types : Array(String) = [] of String

  @reject_undefined_assets : Bool = false
  @asset_metadata_keys : Hash(String, String) = {} of String => String

  # booking_type => bookable asset ids
  @bookable_assets : Hash(String, Set(String)) = {} of String => Set(String)

  def on_update
    @approve_zones = setting?(Array(String), :approve_zones) || [] of String
    @approve_booking_types = setting?(Array(String), :approve_booking_types) || [] of String

    @reject_undefined_assets = setting?(Bool, :reject_undefined_assets) || false
    @asset_metadata_keys = setting?(Hash(String, String), :asset_metadata_keys) || {
      "desk"    => "desks",
      "parking" => "parking-spaces",
    }

    schedule.clear
    schedule.every(10.minutes) { approve_missed }

    if @reject_undefined_assets
      cron = setting?(String, :bookable_assets_cache_cron).presence || "0 0 * * *"
      time_zone = setting?(String, :time_zone).presence
      location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
      schedule.cron(cron, location) { cache_bookable_assets }
      schedule.in(1.second) { cache_bookable_assets }
    else
      @bookable_assets = {} of String => Set(String)
      self[:bookable_assets] = nil
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

  # Caches the asset ids defined in the metadata of the levels of every building
  def cache_bookable_assets
    building_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    assets = {} of String => Set(String)

    @approve_booking_types.each do |booking_type|
      metadata_key = @asset_metadata_keys[booking_type]? || "#{booking_type}s"
      ids = Set(String).new

      building_ids.each do |building_id|
        staff_api.metadata_children(building_id, metadata_key).get.as_a.each do |level|
          next unless details = level.dig?("metadata", metadata_key, "details").try(&.as_a?)
          details.each do |asset|
            if asset_id = asset["id"]?.try(&.as_s?).presence
              ids << asset_id
            end
          end
        end
      end

      assets[booking_type] = ids
    end

    @bookable_assets = assets
    self[:bookable_assets] = assets.transform_values(&.size)
    "cached #{assets.sum(&.[1].size)} bookable assets"
  rescue error
    logger.warn(exception: error) { "failed to cache bookable assets, keeping existing cache" }
    raise error
  end

  private def approve_booking(booking : Booking)
    return if booking.action != "create"

    if !@approve_zones.empty?
      if (booking.zones & @approve_zones).empty?
        logger.debug { "Ignoring booking as no booking zone matches #{booking.id}" }
        return false
      end
    end

    if !@approve_booking_types.empty?
      if !@approve_booking_types.includes?(booking.booking_type)
        logger.debug { "Ignoring booking as booking_type #{booking.booking_type} doesn't match #{booking.id}" }
        return false
      end
    end

    return false if booking.approved || booking.rejected

    if @reject_undefined_assets
      bookable = @bookable_assets[booking.booking_type]?
      if bookable.nil?
        # don't reject bookings because the cache failed to load, approve_missed will retry
        logger.warn { "bookable assets for #{booking.booking_type} not cached, ignoring booking #{booking.id}" }
        return false
      end

      asset_ids = booking.asset_ids.empty? ? [booking.asset_id] : booking.asset_ids
      undefined = asset_ids.reject { |asset_id| bookable.includes?(asset_id) }
      if !undefined.empty?
        staff_api.reject(booking.id, "booking_approval_driver").get
        logger.debug { "Rejected Booking #{booking.id} as assets #{undefined} are not defined in zone metadata" }
        @bookings_rejected += 1
        return false
      end
    end

    # approving booking instances isn't a thing
    staff_api.approve(booking.id).get
    logger.debug { "Approved Booking #{booking.id}" }
    @bookings_approved += 1
    true
  rescue error
    logger.warn(exception: error) { "failed to process booking #{booking.id}" }
  end

  def approve_missed
    booking_type = @approve_booking_types[0]? || "desk"

    bookings = Array(Booking).from_json staff_api.query_bookings(
      type: booking_type,
      zones: [get_building_id],
      approved: false,
      rejected: false,
      period_end: 8.weeks.from_now.to_unix
    ).get_json

    bookings.each do |booking|
      booking.action = "create"
      approve_booking booking
    end

    "found #{bookings.size} missed"
  end

  def status
    {
      bookings_approved: @bookings_approved,
      bookings_rejected: @bookings_rejected,
      bookable_assets:   @bookable_assets.transform_values(&.size),
    }
  end
end
