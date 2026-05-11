require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"
require "../place/booking_model"

# Parking approval driver - allocates parking spaces to bookings based on
# user priority (auto_approval_groups followed by all staff).
#
# Spaces are tracked via the staff API and access is granted via Gallagher
# security groups (mapped through `parking_areas` setting or per-asset via
# `security_system_groups`).
class Place::Parking::Approvals < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Parking Approvals (Gallagher)"
  generic_name :ParkingApprovals
  description %(Auto-allocates parking bookings and grants Gallagher security group access to bookings)

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1
  accessor gallagher : Gallagher_1
  accessor location : LocationServices_1

  protected def mailer
    system.implementing(Interface::Mailer)[0]
  end

  default_settings({
    # auto-allocation runs every 3 hours by default (in minutes)
    poll_rate: 180,

    # max days ahead we'll auto-approve. Capped at 14
    cache_days: 14,

    # ordered AD groups (highest priority first). Group id or email.
    auto_approval_groups: ["azure_group_email_or_id"],

    # ordered list of parking-space FEATURE names that determine allocation
    # preference (earlier = higher priority). Matched against `space.features`,
    # not the asset's zones.
    car_zone_priority:  [] of String,
    bike_zone_priority: [] of String,

    # zone_id (placeos) => gallagher access group id
    parking_areas: {} of String => String,

    # used to resolve booking.extension_data["space_restrictions"] -> feature name
    request_space_restrictions: [
      {id: 1, name: "ACROD"},
      {id: 2, name: "Small car only"},
      {id: 3, name: "Max height 1.9m"},
      {id: 4, name: "Max height 1.95m"},
      {id: 5, name: "Max height 2.1m"},
      {id: 6, name: "Max height 2.2m"},
      {id: 7, name: "Max height 2.3m"},
    ],

    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",
  })

  # max days we will look ahead regardless of cache_days setting
  MAX_LOOKAHEAD_DAYS = 14
  BOOKING_TYPE       = "parking"

  @timezone : Time::Location = Time::Location::UTC
  @poll_rate : Time::Span = 180.minutes
  @auto_approval_groups : Array(String) = [] of String
  @car_zone_priority : Array(String) = [] of String
  @bike_zone_priority : Array(String) = [] of String
  @parking_areas : Hash(String, String) = {} of String => String
  @restriction_lookup : Hash(Int64, String) = {} of Int64 => String
  # restriction features that completely exclude a space from non-matching bookings
  # (e.g. ACROD, Small car only). Height-class restrictions describe capacity
  # rather than exclusivity so they are not added here.
  @exclusive_features : Array(String) = [] of String
  @approval_period : Int32 = 14

  # gallagher group_id => { user_email => cardholder_id }
  # tracks ONLY users we explicitly granted access to. Users who were already
  # members of a group when we tried to grant them access are not tracked
  # (so we never remove access we didn't add)
  @access_granted : Hash(String, Hash(String, String | Int64)) = {} of String => Hash(String, String | Int64)
  @host_access_mutex : Mutex = Mutex.new

  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      booking_changed Booking.from_json(payload)
    end
    on_update
  end

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 180).minutes
    timezone = config.control_system.try(&.timezone).presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)

    @auto_approval_groups = (setting?(Array(String), :auto_approval_groups) || [] of String).map do |id|
      id.includes?('@') ? id.downcase : id
    end

    @car_zone_priority = setting?(Array(String), :car_zone_priority) || [] of String
    @bike_zone_priority = setting?(Array(String), :bike_zone_priority) || [] of String

    raw_areas = setting?(Hash(String, String | Int64), :parking_areas) || {} of String => String | Int64
    @parking_areas = raw_areas.transform_values(&.to_s)

    @restriction_lookup = {} of Int64 => String
    if restrictions = setting?(Array(NamedTuple(id: Int64, name: String)), :request_space_restrictions)
      restrictions.each do |r|
        @restriction_lookup[r[:id]] = r[:name]
      end
    end
    # height restrictions ("Max height ...") describe capacity, not exclusivity.
    # Other named restrictions (ACROD, "Small car only", etc.) reserve a space
    # for matching bookings only.
    @exclusive_features = @restriction_lookup.values.reject(&.starts_with?("Max height"))

    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @approval_period = (setting?(Int32, :cache_days) || MAX_LOOKAHEAD_DAYS).clamp(1, MAX_LOOKAHEAD_DAYS)

    # invalidate caches dependent on settings
    @building_zone = nil
    @parking_spaces_asset_type = nil

    # restore tracked gallagher access from persisted setting so we know what
    # we previously granted across driver restarts
    @host_access_mutex.synchronize do
      @access_granted = setting?(Hash(String, Hash(String, String | Int64)), :access_granted) || {} of String => Hash(String, String | Int64)
    end

    schedule.clear
    schedule.every(@poll_rate) { process_parking_bookings }
  end

  # ===================================
  # Models
  # ===================================

  class ZoneDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property location : String?
    property tags : Array(String) = [] of String
    property parent_id : String?
  end

  struct ParkingSpace
    include JSON::Serializable

    property id : String
    property identifier : String? = nil
    property assigned_to : String? = nil
    property zones : Array(String) = [] of String
    property features : Array(String) = [] of String
    property notes : String? = nil
    property security_system_groups : Array(String) = [] of String
    property bookable : Bool = false
  end

  enum VehicleType
    Car
    Bike

    def self.parse_request(value : String?)
      case value.try(&.downcase)
      when "motorcycle", "motorbike", "bike"
        Bike
      when "car"
        Car
      else
        nil
      end
    end

    def matches_notes?(notes : String?)
      return true if notes.nil? || notes.empty?
      space_type = notes.downcase
      case self
      in .car?
        space_type == "car"
      in .bike?
        space_type.includes?("bike") || space_type.includes?("motor")
      end
    end
  end

  # ===================================
  # Building / asset lookups
  # ===================================

  PARKING_CATEGORY = "_PARKING_"
  PARKING_SPACES   = "_PARKING_SPACES_"

  getter building_id : String { location.building_id.get.as_s }

  @building_zone : ZoneDetails? = nil
  getter building_zone : ZoneDetails do
    ZoneDetails.from_json staff_api.zone(building_id).get.to_json
  end

  @parking_spaces_asset_type : String? = nil
  protected getter parking_spaces_asset_type : String do
    category = staff_api.asset_categories(hidden: true).get.as_a.find { |cat| cat["name"].as_s == PARKING_CATEGORY }
    raise "no parking space asset category (#{PARKING_CATEGORY})" unless category
    type = staff_api.asset_types(category_id: category["id"].as_s).get.as_a.find { |cat| cat["name"].as_s == PARKING_SPACES }
    raise "no #{PARKING_SPACES} asset type configured" unless type
    type["id"].as_s
  end

  # All parking spaces in the building (assigned + bookable)
  def parking_spaces : Array(ParkingSpace)
    Array(ParkingSpace).from_json(
      staff_api.assets(type_id: parking_spaces_asset_type, zones: {building_id}).get.to_json
    )
  rescue error
    logger.error(exception: error) { "failed to query parking spaces" }
    [] of ParkingSpace
  end

  # ===================================
  # Booking event monitoring
  # ===================================

  protected def booking_changed(event)
    return unless event.booking_type == BOOKING_TYPE
    return unless event.zones.includes?(building_id)

    case event.action
    when "create", "approved", "cancelled", "rejected", "changed"
      # Re-run auto allocation. The full sweep handles approvals,
      # cleanup of cancelled bookings, and waitlist preemption.
      spawn { process_parking_bookings }
    else
      logger.debug { "booking event #{event.action} ignored" }
    end
  rescue error
    logger.error(exception: error) { "failed to handle booking_changed event" }
  end

  # ===================================
  # Auto allocation entry point
  # ===================================

  @sync_mutex : Mutex = Mutex.new
  @sync_requests : UInt32 = 0_u32
  @syncing : Bool = false

  def process_parking_bookings
    @sync_requests += 1
    return "already processing" if @syncing

    @sync_mutex.synchronize do
      begin
        @syncing = true
        @sync_requests = 0
        run_allocation
      ensure
        @syncing = false
      end
    end

    spawn { process_parking_bookings } if @sync_requests > 0
    "parking allocated"
  end

  # ===================================
  # Allocation core
  # ===================================

  protected def run_allocation
    starting = Time.utc.to_unix
    ending = @approval_period.days.from_now.to_unix

    spaces = parking_spaces
    spaces_by_id = spaces.each_with_object({} of String => ParkingSpace) { |s, h| h[s.id] = s }
    bookable_spaces = spaces.select { |s| s.bookable && s.assigned_to.presence.nil? }
    assigned_spaces = spaces.select { |s| s.assigned_to.presence }

    logger.debug { "allocation run: #{spaces.size} spaces total, #{bookable_spaces.size} bookable, #{assigned_spaces.size} permanently assigned" }

    bookings = fetch_bookings(starting, ending)
    logger.debug { "allocation run: processing #{bookings.size} active bookings" }

    # Calculate priority for each booking and group lookup is cached per-user
    user_priority_cache = {} of String => Int32
    booking_meta = bookings.map do |booking|
      priority = priority_for(booking, user_priority_cache)
      {booking, priority}
    end

    # Sort: priority desc, then created asc (older first)
    booking_meta.sort! do |a, b|
      cmp = b[1] <=> a[1]
      cmp == 0 ? (a[0].created || 0_i64) <=> (b[0].created || 0_i64) : cmp
    end

    # Track current allocations: asset_id => {booking, priority}
    current_allocations = {} of String => Tuple(Booking, Int32)
    booking_meta.each do |(booking, priority)|
      asset_id = booking.asset_ids.first?
      next if asset_id.nil? || asset_id.starts_with?("unallocated")
      current_allocations[asset_id] = {booking, priority}
    end

    # First pass: ensure already-allocated bookings are approved + emailed.
    # Gallagher access is reconciled in one shot at the end of the run.
    booking_meta.each do |(booking, _priority)|
      next if booking.rejected || booking.deleted
      asset_id = booking.asset_ids.first?
      next if asset_id.nil? || asset_id.starts_with?("unallocated")

      space = spaces_by_id[asset_id]?
      if space.nil?
        logger.warn { "booking #{booking.id} references unknown parking space #{asset_id}" }
        next
      end

      handle_allocated_booking(booking, space)
    end

    # Second pass: process unallocated bookings in priority order
    booking_meta.each do |(booking, priority)|
      next if booking.rejected || booking.deleted
      asset_id = booking.asset_ids.first?
      next if asset_id && !asset_id.starts_with?("unallocated")

      handle_unallocated_booking(booking, priority, bookable_spaces, current_allocations)
    end

    # Compute desired gallagher access from the FINAL booking state, then diff
    # against @access_granted and apply only the additions/removals we own.
    desired_access = build_desired_access(booking_meta, spaces_by_id, assigned_spaces)
    apply_access_changes(desired_access)
  end

  # Walk the final booking + permanent-assignment state and emit the gallagher
  # group memberships we want to be in place. Bookings whose asset_ids start
  # with "unallocated" are skipped (no allocated space => no access).
  protected def build_desired_access(
    booking_meta : Array(Tuple(Booking, Int32)),
    spaces_by_id : Hash(String, ParkingSpace),
    assigned_spaces : Array(ParkingSpace),
  ) : Hash(String, Hash(String, String | Int64))
    desired = {} of String => Hash(String, String | Int64)

    booking_meta.each do |(booking, _priority)|
      next if booking.rejected || booking.deleted
      asset_id = booking.asset_ids.first?
      next if asset_id.nil? || asset_id.starts_with?("unallocated")
      space = spaces_by_id[asset_id]?
      next unless space
      record_desired_access(desired, booking.user_email, space)
    end

    assigned_spaces.each do |space|
      assignee = space.assigned_to
      next unless assignee && !assignee.empty?
      record_desired_access(desired, assignee, space)
    end

    desired
  end

  protected def record_desired_access(
    desired : Hash(String, Hash(String, String | Int64)),
    user_email : String,
    space : ParkingSpace,
  ) : Nil
    group_ids = gallagher_group_ids_for(space)
    if group_ids.empty?
      logger.warn { "no gallagher group configured for space #{space.id} (zones: #{space.zones})" }
      return
    end

    cardholder_id = lookup_cardholder(user_email)
    if cardholder_id.nil?
      logger.warn { "no gallagher cardholder for #{user_email}" }
      return
    end

    email_key = user_email.downcase
    group_ids.each do |gid|
      bucket = desired[gid] ||= {} of String => String | Int64
      bucket[email_key] = cardholder_id
    end
  end

  # Diff desired against @access_granted:
  #  - users no longer required have their access removed
  #  - new users are granted access, unless they were ALREADY a group member
  #    (someone else gave them access — we don't take responsibility for them)
  #  - users present in both are left untouched
  # Updates @access_granted with the resulting tracked state and persists it.
  protected def apply_access_changes(desired : Hash(String, Hash(String, String | Int64))) : Nil
    all_groups = (@access_granted.keys + desired.keys).uniq
    new_state = {} of String => Hash(String, String | Int64)

    all_groups.each do |group_id|
      new_users = desired[group_id]? || {} of String => String | Int64
      old_users = @access_granted[group_id]? || {} of String => String | Int64

      tracked = {} of String => String | Int64

      # remove users we previously granted but that are no longer required
      (old_users.keys - new_users.keys).each do |email|
        cardholder_id = old_users[email]
        begin
          gallagher.zone_access_remove_member(group_id, cardholder_id).get
          logger.debug { "removed #{email} from gallagher group #{group_id}" }
        rescue error
          logger.warn(exception: error) { "failed removing #{email} from gallagher group #{group_id}" }
        end
      end

      # users in both — already granted by us, keep tracking, no API call
      (new_users.keys & old_users.keys).each do |email|
        tracked[email] = new_users[email]
      end

      # new users — grant access, but skip those who were already members
      (new_users.keys - old_users.keys).each do |email|
        cardholder_id = new_users[email]
        begin
          already_member = nil.as(JSON::Any::Type)
          begin
            already_member = gallagher.zone_access_member?(group_id, cardholder_id).get.raw
          rescue
            already_member = nil
          end

          if already_member
            logger.debug { "#{email} already a member of gallagher group #{group_id}, leaving untouched" }
            next
          end

          gallagher.zone_access_add_member(group_id, cardholder_id).get
          tracked[email] = cardholder_id
          logger.debug { "granted #{email} access to gallagher group #{group_id}" }
        rescue error
          logger.warn(exception: error) { "failed adding #{email} to gallagher group #{group_id}" }
        end
      end

      new_state[group_id] = tracked unless tracked.empty?
    end

    @host_access_mutex.synchronize do
      @access_granted = new_state
      begin
        define_setting(:access_granted, @access_granted)
      rescue error
        logger.warn(exception: error) { "failed to persist access_granted setting" }
      end
    end
  end

  # ===================================
  # Fetch bookings
  # ===================================

  protected def fetch_bookings(starting : Int64, ending : Int64) : Array(Booking)
    Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: [building_id],
      period_start: starting,
      period_end: ending,
      limit: 10_000,
    ).get.to_json)
  rescue error
    logger.error(exception: error) { "failed to query parking bookings" }
    [] of Booking
  end

  # ===================================
  # Priority calculation
  # ===================================

  # higher number = higher priority. 0 is "default staff".
  protected def priority_for(booking : Booking, cache : Hash(String, Int32)) : Int32
    user_email = booking.user_email.downcase
    base = cache[user_email]?
    if base.nil?
      base = group_priority(user_email)
      cache[user_email] = base
    end

    request_type = booking.extension_data["request_type"]?.try(&.as_s?)
    if request_type == "after_hours"
      # after hours bookings need manual approval; if approved bump priority
      return base + 100 if booking.approved
      # not approved yet - keep base priority but flag separately
      return base
    end

    base
  end

  protected def group_priority(user_email : String) : Int32
    return 0 if @auto_approval_groups.empty?

    groups = calendar.get_groups(user_email).get.as_a rescue [] of JSON::Any

    @auto_approval_groups.each_with_index do |target, idx|
      groups.each do |g|
        gid = g["id"]?.try(&.as_s?)
        gemail = g["email"]?.try(&.as_s?).try(&.downcase)
        if gid == target || gemail == target
          # earliest entry => highest priority
          return @auto_approval_groups.size - idx
        end
      end
    end
    0
  rescue error
    logger.warn(exception: error) { "failed to lookup groups for #{user_email}" }
    0
  end

  # ===================================
  # Already-allocated bookings
  # ===================================

  protected def handle_allocated_booking(booking : Booking, space : ParkingSpace) : Nil
    return if booking.process_state == "access_granted"

    logger.debug { "approval/email for already-allocated booking #{booking.id} (#{booking.user_email}) on space #{space.id}" }

    # If the booking has not been approved yet, approve it
    unless booking.approved
      begin
        staff_api.approve(booking.id, booking.instance).get
        booking.approved = true
      rescue error
        logger.warn(exception: error) { "failed to approve booking #{booking.id}" }
      end
    end

    approved_email(booking, space)
  rescue error
    logger.error(exception: error) { "failed to process allocated booking #{booking.id}" }
  end

  # ===================================
  # Unallocated bookings
  # ===================================

  protected def handle_unallocated_booking(
    booking : Booking,
    priority : Int32,
    bookable_spaces : Array(ParkingSpace),
    current_allocations : Hash(String, Tuple(Booking, Int32)),
  ) : Nil
    request_type = booking.extension_data["request_type"]?.try(&.as_s?)

    # After hours bookings cannot be auto-approved
    if request_type == "after_hours" && !booking.approved
      logger.debug { "booking #{booking.id} requires manual approval (after hours)" }
      waiting_approval_email(booking)
      return
    end

    compatible = sort_by_zone_priority(compatible_spaces(booking, bookable_spaces), booking)
    if compatible.empty?
      logger.warn { "no compatible spaces for booking #{booking.id} (vehicle/restriction filter)" }
      wait_list_email(booking)
      return
    end

    # Filter out spaces in-use during this booking's window
    busy_assets = busy_asset_ids_during(booking, current_allocations)
    available = compatible.reject { |s| busy_assets.includes?(s.id) }

    if !available.empty?
      space = available.first
      allocate(booking, space, current_allocations, priority)
      return
    end

    # No free space — try preemption (find lower priority allocation we can displace)
    target_asset = compatible.find do |space|
      conflict = current_allocations[space.id]?
      conflict && conflict[1] < priority && bookings_overlap?(booking, conflict[0])
    end

    if target_asset
      conflict = current_allocations[target_asset.id]
      logger.info { "preempting booking #{conflict[0].id} (priority #{conflict[1]}) for higher priority booking #{booking.id} (priority #{priority})" }
      displace_booking(conflict[0], target_asset)
      current_allocations.delete(target_asset.id)
      allocate(booking, target_asset, current_allocations, priority)
    else
      logger.debug { "no preemption candidate for booking #{booking.id}, sending wait list email" }
      wait_list_email(booking)
    end
  rescue error
    logger.error(exception: error) { "failed to process unallocated booking #{booking.id}" }
  end

  # Find bookings whose asset_ids are in-use at the same time as `booking`
  protected def busy_asset_ids_during(
    booking : Booking,
    current_allocations : Hash(String, Tuple(Booking, Int32)),
  ) : Set(String)
    busy = Set(String).new
    current_allocations.each do |asset_id, (other, _)|
      next if other.id == booking.id
      busy << asset_id if bookings_overlap?(booking, other)
    end
    busy
  end

  protected def bookings_overlap?(a : Booking, b : Booking) : Bool
    a.booking_start < b.booking_end && b.booking_start < a.booking_end
  end

  # ===================================
  # Compatibility filter
  # ===================================

  protected def compatible_spaces(booking : Booking, spaces : Array(ParkingSpace)) : Array(ParkingSpace)
    vehicle = VehicleType.parse_request(booking.extension_data["vehicle_type"]?.try(&.as_s?))

    restriction_id = booking.extension_data["space_restrictions"]?.try(&.as_i64?)
    restriction_name = restriction_id ? @restriction_lookup[restriction_id]? : nil

    spaces.select do |space|
      vehicle_ok = vehicle.nil? || vehicle.matches_notes?(space.notes)

      restriction_ok = if restriction_name
                         space.features.includes?(restriction_name)
                       else
                         (space.features & @exclusive_features).empty?
                       end

      vehicle_ok && restriction_ok
    end
  end

  protected def sort_by_zone_priority(spaces : Array(ParkingSpace), booking : Booking) : Array(ParkingSpace)
    vehicle = VehicleType.parse_request(booking.extension_data["vehicle_type"]?.try(&.as_s?))
    priority_features = case vehicle
                        when VehicleType::Bike
                          @bike_zone_priority
                        else
                          @car_zone_priority
                        end

    return spaces if priority_features.empty?

    spaces.sort_by do |space|
      idx = Int32::MAX
      priority_features.each_with_index do |feature, i|
        if space.features.includes?(feature)
          idx = i
          break
        end
      end
      idx
    end
  end

  # ===================================
  # Allocate / displace / approve
  # ===================================

  protected def allocate(
    booking : Booking,
    space : ParkingSpace,
    current_allocations : Hash(String, Tuple(Booking, Int32)),
    priority : Int32,
  ) : Nil
    logger.debug { "allocating booking #{booking.id} -> space #{space.id}" }
    booking.asset_id = space.id
    booking.asset_ids = [space.id]

    staff_api.update_booking(
      booking_id: booking.id,
      asset_id: space.id,
      instance: booking.instance,
    ).get

    staff_api.approve(booking.id, booking.instance).get
    booking.approved = true

    current_allocations[space.id] = {booking, priority}
    approved_email(booking, space)
  rescue error
    logger.error(exception: error) { "failed to allocate booking #{booking.id} to space #{space.id}" }
  end

  protected def displace_booking(booking : Booking, space : ParkingSpace) : Nil
    logger.info { "displacing booking #{booking.id} (#{booking.user_email}) from space #{space.id}" }

    placeholder = "unallocated-displaced-#{booking.id}"
    booking.asset_id = placeholder
    booking.asset_ids = [placeholder]

    begin
      staff_api.update_booking(
        booking_id: booking.id,
        asset_id: placeholder,
        instance: booking.instance,
      ).get
    rescue error
      logger.warn(exception: error) { "failed to revert booking #{booking.id} asset_id" }
    end

    displaced_email(booking)
  rescue error
    logger.error(exception: error) { "failed to displace booking #{booking.id}" }
  end

  # ===================================
  # Gallagher access management
  # ===================================

  protected def gallagher_group_ids_for(space : ParkingSpace) : Array(String)
    return space.security_system_groups.dup unless space.security_system_groups.empty?
    space.zones.compact_map { |zone_id| @parking_areas[zone_id]? }
  end

  @cardholder_cache : Hash(String, String | Int64) = {} of String => String | Int64

  protected def lookup_cardholder(user_email : String) : String | Int64 | Nil
    user_email = user_email.downcase
    if cached = @cardholder_cache[user_email]?
      return cached
    end

    json = gallagher.card_holder_id_lookup(user_email).get
    raw = json.raw
    return nil if raw.nil?

    case raw
    when String
      @cardholder_cache[user_email] = raw
    when Int
      @cardholder_cache[user_email] = raw.to_i64
    else
      nil
    end
  rescue error
    logger.warn(exception: error) { "cardholder lookup failed for #{user_email}" }
    nil
  end

  # ===================================
  # Mailer templates
  # ===================================

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(@timezone)
    common_fields = [
      {name: "visitor_email", description: "Email address of the parking user"},
      {name: "visitor_name", description: "Full name of the parking user"},
      {name: "building_name", description: "Name of the building the parking space is located"},
      {name: "parking_start", description: "Start time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "parking_date", description: "Date of the visit (e.g., #{time_now.to_s(@date_format)})"},
      {name: "parking_time", description: "Number hours booking is valid for (or 'all day' for 24-hours)"},
      {name: "space_identifier", description: "Identifier of the allocated parking space"},
    ]

    [
      TemplateFields.new(
        trigger: {"parking_request", "approved"},
        name: "Parking Approved",
        description: "Notifies the recipient that their parking is approved and access has been granted",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "wait_list"},
        name: "Parking Wait List",
        description: "Notifies the recipient that there is no parking available, they may obtain a spot if someone cancels",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "approval_required"},
        name: "Parking Approval Required",
        description: "Notifies the recipient that approval is required (after hours bookings)",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "displaced"},
        name: "Parking Displaced",
        description: "Notifies the recipient that their parking allocation has been moved to the wait list",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "rejected"},
        name: "Parking Rejected",
        description: "Notifies the recipient that their parking booking has been rejected",
        fields: common_fields
      ),
    ]
  end

  protected def common_template_args(booking : Booking, space : ParkingSpace? = nil)
    local_start = Time.unix(booking.booking_start).in(@timezone)
    local_end = Time.unix(booking.booking_end).in(@timezone)
    span = local_end - local_start
    period = if booking.all_day || span == 24.hours
               "all day"
             else
               "#{span.total_hours}hours"
             end

    {
      visitor_email:    booking.user_email,
      visitor_name:     booking.user_name,
      building_name:    building_zone.display_name.presence || building_zone.name,
      parking_start:    local_start.to_s(@time_format),
      parking_date:     local_start.to_s(@date_format),
      parking_time:     period,
      space_identifier: space.try(&.identifier) || space.try(&.id) || "",
    }
  end

  protected def approved_email(booking : Booking, space : ParkingSpace) : Nil
    return if booking.process_state == "access_granted"

    mailer.send_template(
      booking.user_email,
      {"parking_request", "approved"},
      common_template_args(booking, space),
    )

    update_state(booking, "access_granted")
  rescue error
    logger.warn(exception: error) { "failed to send approved email for booking #{booking.id}" }
  end

  WAITING_SENT = {"waiting_approval", "access_granted"}

  protected def waiting_approval_email(booking : Booking) : Nil
    return if WAITING_SENT.includes?(booking.process_state)

    mailer.send_template(
      booking.user_email,
      {"parking_request", "approval_required"},
      common_template_args(booking),
    )

    update_state(booking, "waiting_approval")
  rescue error
    logger.warn(exception: error) { "failed to send waiting approval email for booking #{booking.id}" }
  end

  WAIT_LIST_SENT = {"wait_list", "access_granted"}

  protected def wait_list_email(booking : Booking) : Nil
    return if WAIT_LIST_SENT.includes?(booking.process_state)

    mailer.send_template(
      booking.user_email,
      {"parking_request", "wait_list"},
      common_template_args(booking),
    )

    update_state(booking, "wait_list")
  rescue error
    logger.warn(exception: error) { "failed to send wait list email for booking #{booking.id}" }
  end

  protected def displaced_email(booking : Booking) : Nil
    mailer.send_template(
      booking.user_email,
      {"parking_request", "displaced"},
      common_template_args(booking),
    )

    update_state(booking, "wait_list")
  rescue error
    logger.warn(exception: error) { "failed to send displaced email for booking #{booking.id}" }
  end

  protected def update_state(booking : Booking, state : String) : Nil
    staff_api.booking_state(
      booking_id: booking.id,
      state: state,
      instance: booking.instance,
    ).get
    booking.process_state = state
  rescue error
    logger.warn(exception: error) { "failed to update process_state #{state} for booking #{booking.id}" }
  end
end
