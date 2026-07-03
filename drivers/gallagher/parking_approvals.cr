require "base64"
require "simple_retry"
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
# `security_system_groups`)
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

    # ordered AD groups (highest priority first). Group id or email.
    auto_approval_groups: ["azure_group_email_or_id"],

    # accurate group priority is critical, so a failing directory group lookup is
    # retried with exponential backoff before giving up (the user is then treated
    # as priority 0 for that run ONLY and retried next sweep). Tuning knobs
    # (seconds); the defaults retry 5 times, 2s → 30s.
    _group_lookup_retries:     5,
    _group_lookup_backoff:     2,
    _group_lookup_max_backoff: 30,

    # ordered list of parking-space FEATURE names that determine allocation
    # preference (earlier = higher priority). Matched against `space.features`,
    # not the asset's zones.
    car_zone_priority:  [] of String,
    bike_zone_priority: [] of String,

    # parking-space FEATURE name => gallagher access group / zone id. A space's
    # features (e.g. "Open Basement", "Secure Basement") are matched against
    # these keys to find which Gallagher group(s) to grant access to.
    parking_areas: {} of String => String,

    # minutes before a booking's start that Gallagher access should begin. The
    # access window ends at the booking end. Changing this only affects future
    # grants (existing grants are matched/removed by their end time, not start).
    access_minutes_before: 30,

    # when false, existing allocations are never displaced: higher priority
    # bookings wait for a free space instead of bumping lower priority users,
    # and bookings on spaces that lose their gallagher mapping stay put (still
    # reported via the spaces_without_groups status)
    allow_displacement: true,

    # a booking can't be displaced (preempted, or moved off an unmapped space)
    # within this many hours of its start time — users get this much notice. Set
    # to 0 to disable. Forced moves (a space taken out of service) still proceed.
    displacement_notification_hours: 24,

    # When set, Gallagher cardholders are resolved by first looking the user up
    # in the directory (MS Graph) and reading this field from `user.unmapped`
    # (e.g. an "employeeId" custom attribute), then querying Gallagher with that
    # value. Leave blank to query Gallagher directly by email.
    gallagher_id_field: "",

    # Directory `additional_fields` requested when resolving a user (e.g.
    # ["employeeid"]). Defaults to [gallagher_id_field] when blank. Override
    # only if the requested field name differs from the unmapped key returned
    # (MS Graph may camelCase a requested "employeeid" to "employeeId").
    directory_lookup_fields: [] of String,

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

    # When set, parking approval emails carry a calendar invite (.ics) so the
    # allocated space appears on the user's calendar; a matching cancellation is
    # sent if they're later displaced. This is the organizer ("from") address
    # shown on the invite — typically a no-reply mailbox. Leave blank to disable.
    calendar_invite_from:      "",
    calendar_invite_from_name: "Parking",
  })

  BOOKING_TYPE = "parking"

  @timezone : Time::Location = Time::Location::UTC
  @poll_rate : Time::Span = 180.minutes
  @auto_approval_groups : Array(String) = [] of String
  # directory group-lookup retry policy (see group_priority)
  @group_lookup_retries : Int32 = 5
  @group_lookup_backoff : Time::Span = 2.seconds
  @group_lookup_max_backoff : Time::Span = 30.seconds
  @car_zone_priority : Array(String) = [] of String
  @bike_zone_priority : Array(String) = [] of String
  @parking_areas : Hash(String, String) = {} of String => String
  # minutes of access granted before a booking starts (access ends at booking end)
  @access_minutes_before : Int32 = 30
  # when false no booking is ever moved off its space (no preemption, no
  # unmapped-space moves)
  @allow_displacement : Bool = true
  # bookings starting within this many hours can't be (non-forced) displaced
  @displacement_notification_hours : Int32 = 24
  getter restriction_lookup : Hash(Int64, String) = {} of Int64 => String
  # restriction features that completely exclude a space from non-matching bookings
  # (e.g. ACROD, Small car only). Height-class restrictions describe capacity
  # rather than exclusivity so they are not added here.
  getter exclusive_features : Array(String) = [] of String
  # height restriction names ordered by id (strictly increasing height); the
  # index is the relative height rank used for ">= match" and closest-fit sorting
  getter height_features : Array(String) = [] of String

  # directory (MS Graph) field whose value identifies the user in Gallagher.
  # When blank, Gallagher is queried directly by email.
  @gallagher_id_field : String? = nil
  # additional_fields requested from the directory when resolving a user
  @directory_lookup_fields : Array(String) = [] of String

  # cardholder lookup failures recorded during the current sync (cleared at the
  # start of each run, surfaced via the :lookup_errors status for reporting)
  @lookup_errors : Array(LookupError) = [] of LookupError
  # emails that already failed to resolve this sync — avoids repeating the
  # directory/Gallagher calls (and duplicate error records) for a user that
  # appears across multiple bookings in the same run
  @failed_lookups : Set(String) = Set(String).new
  # downcased email => a booking of theirs this run, so the no-card email
  # (sent in publish_lookup_errors) has booking context. Cleared each run.
  @no_card_bookings : Hash(String, Booking) = {} of String => Booking

  # Users (downcased emails) we could not resolve to a Gallagher cardholder.
  # Recomputed from each run's lookup errors and persisted to settings so the
  # "no access card" notification is sent only once per user (until they resolve
  # to a card). A booking for one of these users is withheld until they have a
  # card.
  @no_card_users : Array(String) = [] of String
  @no_card_mutex : Mutex = Mutex.new

  # A user we could not resolve to a Gallagher cardholder. `employee_id` is the
  # resolved directory value when available (nil when the directory lookup
  # itself failed to yield one).
  struct LookupError
    include JSON::Serializable

    getter email : String

    # always present in the JSON (null when the directory lookup yielded no id)
    # so reporting consumers see a stable schema
    @[JSON::Field(emit_null: true)]
    getter employee_id : String?

    getter reason : String

    def initialize(@email, @employee_id, @reason)
    end
  end

  # A Gallagher access grant we made. Booking grants are time-bounded
  # (until_unix = booking end); permanent (assigned-space) grants have a nil
  # window. `from_unix` is recomputed each sweep from access_minutes_before and
  # is only used when (re)adding — it is intentionally NOT persisted so changing
  # access_minutes_before doesn't orphan tracked grants (we match on until).
  struct Grant
    include JSON::Serializable

    getter email : String
    getter cardholder_id : String | Int64

    @[JSON::Field(emit_null: true)]
    getter until_unix : Int64?

    @[JSON::Field(ignore: true)]
    getter from_unix : Int64?

    def initialize(@email, @cardholder_id, @until_unix, @from_unix = nil)
    end
  end

  # gallagher group_id => { grant_key => Grant }, where grant_key combines the
  # user email and the grant's until time so a user can hold several distinct
  # time windows in one group (e.g. parking on several days of the week).
  # Tracks ONLY grants we made; users already a member with a matching window
  # are left untouched (we never remove access we didn't add).
  @access_granted : Hash(String, Hash(String, Grant)) = {} of String => Hash(String, Grant)
  @host_access_mutex : Mutex = Mutex.new

  protected def grant_key(email : String, until_unix : Int64?) : String
    "#{email.downcase}|#{until_unix}"
  end

  # Restore @access_granted from settings, tolerating the legacy pre-window
  # format (group => { email => cardholder_id }). Legacy entries become
  # permanent grants (nil window); the next sweep's diff then removes them and
  # re-adds the correct time-bounded grants.
  protected def restore_access_granted : Hash(String, Hash(String, Grant))
    empty = {} of String => Hash(String, Grant)
    raw = setting?(JSON::Any, :access_granted)
    return empty unless raw
    json = raw.to_json

    begin
      return Hash(String, Hash(String, Grant)).from_json(json)
    rescue
      # not the current format — try the legacy one below
    end

    begin
      legacy = Hash(String, Hash(String, String | Int64)).from_json(json)
      migrated = {} of String => Hash(String, Grant)
      legacy.each do |group, users|
        bucket = migrated[group] = {} of String => Grant
        users.each do |email, cardholder_id|
          bucket[grant_key(email, nil)] = Grant.new(email, cardholder_id, nil)
        end
      end
      logger.info { "migrated legacy access_granted (#{migrated.size} group(s)) to time-windowed format" }
      return migrated
    rescue error
      logger.warn(exception: error) { "could not restore access_granted, starting fresh" }
    end

    empty
  end

  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  # organizer identity for calendar invites; when the email is blank invites are
  # disabled (approval/displacement emails carry no .ics attachment)
  @calendar_invite_from : String? = nil
  @calendar_invite_from_name : String = "Parking"

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

    previous_auto_approval_groups = @auto_approval_groups
    @auto_approval_groups = (setting?(Array(String), :auto_approval_groups) || [] of String).map do |id|
      id.includes?('@') ? id.downcase : id
    end

    @group_lookup_retries = setting?(Int32, :group_lookup_retries) || 5
    @group_lookup_backoff = (setting?(Int32, :group_lookup_backoff) || 2).seconds
    @group_lookup_max_backoff = (setting?(Int32, :group_lookup_max_backoff) || 30).seconds

    @car_zone_priority = setting?(Array(String), :car_zone_priority) || [] of String
    @bike_zone_priority = setting?(Array(String), :bike_zone_priority) || [] of String

    raw_areas = setting?(Hash(String, String | Int64), :parking_areas) || {} of String => String | Int64
    @parking_areas = raw_areas.transform_values(&.to_s)

    @access_minutes_before = setting?(Int32, :access_minutes_before) || 30
    @allow_displacement = setting?(Bool, :allow_displacement) != false
    @displacement_notification_hours = setting?(Int32, :displacement_notification_hours) || 24

    @restriction_lookup = {} of Int64 => String
    if restrictions = setting?(Array(NamedTuple(id: Int64, name: String)), :request_space_restrictions)
      restrictions.each do |r|
        @restriction_lookup[r[:id]] = r[:name]
      end
    end
    # height restrictions ("Max height ...") describe capacity, not exclusivity.
    # Other named restrictions (ACROD, etc.) reserve a space
    # for matching bookings only.
    @exclusive_features = @restriction_lookup.values.reject do |name|
      name.starts_with?("Max") || name.starts_with?("Small")
    end

    # height restriction names ordered by id (= strictly increasing height). The
    # index in this list is a space's / booking's relative height rank: a space
    # accommodates a booking when its rank is >= the booking's required rank.
    @height_features = @restriction_lookup.to_a
      .select { |(_id, name)| name.starts_with?("Max") || name.starts_with?("Small") }
      .sort_by! { |(id, _name)| id }
      .map { |(_id, name)| name }

    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @calendar_invite_from = setting?(String, :calendar_invite_from).presence
    @calendar_invite_from_name = setting?(String, :calendar_invite_from_name).presence || "Parking"

    previous_id_field = @gallagher_id_field
    previous_lookup_fields = @directory_lookup_fields

    @gallagher_id_field = setting?(String, :gallagher_id_field).presence
    lookup_fields = setting?(Array(String), :directory_lookup_fields) || [] of String
    # default the requested directory fields to the id field itself
    if lookup_fields.empty? && (field = @gallagher_id_field)
      lookup_fields = [field]
    end
    @directory_lookup_fields = lookup_fields

    # invalidate caches dependent on settings
    @building_zone = nil
    @parking_spaces_asset_type = nil
    # Only flush the cardholder cache when the lookup MECHANISM changed (a
    # different id field resolves users to different cardholders). on_update also
    # fires on the define_setting writes we make every sweep, so flushing here
    # unconditionally would defeat the cache and hammer the directory/Gallagher
    # on every run. Otherwise it's flushed once a day (see the cron below).
    if previous_id_field != @gallagher_id_field || previous_lookup_fields != @directory_lookup_fields
      clear_cardholder_cache
    end
    # the priority cache holds each user's base group_priority, which depends on
    # auto_approval_groups — flush it when that list changes (otherwise daily)
    if previous_auto_approval_groups != @auto_approval_groups
      clear_priority_cache
    end

    # restore tracked gallagher access from persisted setting so we know what
    # we previously granted across driver restarts
    @host_access_mutex.synchronize do
      @access_granted = restore_access_granted
    end

    # restore the persisted list of users with no Gallagher card so we don't
    # re-notify them every restart
    @no_card_mutex.synchronize do
      @no_card_users = setting?(Array(String), :users_without_cards) || [] of String
    end

    schedule.clear
    schedule.every(@poll_rate) { process_parking_bookings }
    # flush the cardholder + priority lookup caches once a day (midnight, building
    # timezone) so newly-issued cards and AD group changes are picked up without
    # keeping stale lookups forever
    schedule.cron("0 0 * * *", @timezone) do
      clear_cardholder_cache
      clear_priority_cache
    end
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
    ZoneDetails.from_json staff_api.zone(building_id).get_json
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
  # Raises on failure: callers must treat a failed fetch as "unknown", NOT as
  # "no spaces" — an empty list would let the run revoke all access (see
  # run_allocation).
  def parking_spaces : Array(ParkingSpace)
    Array(ParkingSpace).from_json(
      staff_api.assets(type_id: parking_spaces_asset_type, zones: {building_id}).get_json
    )
  rescue error
    logger.error(exception: error) { "failed to query parking spaces" }
    raise error
  end

  # ===================================
  # Booking event monitoring
  # ===================================

  protected def booking_changed(event)
    return unless event.booking_type == BOOKING_TYPE
    return unless event.zones.includes?(building_id)

    case event.action
    when "cancelled"
      # The sweep reconciles (removes) access, but a cancelled booking drops out
      # of the fetch, so the notification + calendar cancellation are sent here
      # from the event payload before the sweep runs.
      handle_cancellation(event)
      spawn { process_parking_bookings }
    when "create", "approved", "rejected", "changed"
      # Re-run auto allocation. The full sweep handles approvals,
      # cleanup of cancelled bookings, and waitlist preemption.
      spawn { process_parking_bookings }
    else
      logger.debug { "booking event #{event.action} ignored" }
    end
  rescue error
    logger.error(exception: error) { "failed to handle booking_changed event" }
  end

  # A user cancelled a booking. Access removal is handled by the sweep (the
  # booking drops out of the fetch, so its grant is diffed away), but the sweep
  # never sees a cancelled booking — so the notification + calendar cancellation
  # are sent here from the event payload. Only bookings that actually held a
  # space are notified: one that was only ever wait-listed never received an
  # invite or access, so there is nothing to cancel. A per-booking state marker
  # keeps a repeated event from re-notifying.
  protected def handle_cancellation(booking : Booking) : Nil
    return if booking.process_state == "cancelled_emailed"

    asset_id = booking.asset_ids.first?
    return if asset_id.nil? || asset_id.starts_with?("unallocated")

    logger.debug { "sending cancellation notice for booking #{booking.id} (#{booking.user_email})" }

    # the space the booking held (persisted on allocate) labels the cancellation;
    # nil just yields a generic cancel that still removes the entry by UID
    label = booking.extension_data["location"]?.try(&.as_s?)
    mailer.send_template(
      booking.user_email,
      {"parking_request", "cancelled"},
      common_template_args(booking).merge({space_identifier: label || ""}),
      attachments: calendar_attachment(booking, label, cancel: true),
    ).get_json

    # mark handled so a repeated cancellation event doesn't re-notify
    update_state(booking, "cancelled_emailed")
  rescue error
    logger.warn(exception: error) { "failed to send cancellation email for booking #{booking.id}" }
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
      rescue error
        # never let a sweep failure escape as an unhandled fiber exception
        # (process_parking_bookings is also invoked from spawn in booking_changed)
        logger.error(exception: error) { "parking allocation run failed" }
      ensure
        @syncing = false
        # service any request that coalesced while we were running, even on error
        schedule.in(10.seconds) { process_parking_bookings } if @sync_requests > 0
      end
    end

    "parking allocated"
  end

  # Manually reassign parking spaces (e.g. for an event). `displace` maps an
  # `email_to_displace => email_to_assign`: for each pair the displaced user's
  # parking booking(s) starting at `start_time` are moved off their space and
  # that space is given to the assignee — creating a wait-list booking for the
  # assignee first if they don't already have one for that time. Both sides are
  # notified; Gallagher access is reconciled on the next allocation sweep.
  def manual_displacement(start_time : Int64, displace : Hash(String, String)) : String
    @sync_mutex.synchronize do
      spaces_by_id = parking_spaces.each_with_object({} of String => ParkingSpace) { |s, h| h[s.id] = s }

      # Phase 1: pair each displaced booking with the booking that will take its
      # space, creating a wait-list booking for the assignee when one is missing.
      swaps = [] of NamedTuple(displace: Booking, assign: Booking, space: ParkingSpace)
      displace.each do |displace_email, assign_email|
        displace_bookings = bookings_for(displace_email, start_time)
        next if displace_bookings.empty?
        assign_bookings = bookings_for(assign_email, start_time)

        displace_bookings.each_with_index do |db, i|
          space = (sid = db.asset_ids.first?) ? spaces_by_id[sid]? : nil
          unless space
            logger.warn { "manual displacement: #{displace_email} booking #{db.id} is not on a known parking space; skipping" }
            next
          end
          # an existing assignee booking is matched by order; otherwise create one
          assignee = assign_bookings[i]? || create_manual_booking(db, assign_email)
          next unless assignee
          swaps << {displace: db, assign: assignee, space: space}
        end
      end

      logger.info { "manual displacement: reassigning #{swaps.size} space(s)" }

      # Phase 2: displace + notify the displaced users (forced — bypasses the
      # allow_displacement / notice-period policies; this is an explicit action)
      swaps.each do |swap|
        booking = swap[:displace]
        next unless displace_booking(booking, swap[:space], forced: true)
        update_state(booking, "wait_list")
        displaced_email(booking, "Your parking space has been reassigned.")
      end

      # Phase 3: assign the freed spaces to the assignees + notify (allocate sends
      # the approval email and approves the booking)
      throwaway = {} of String => Array(Tuple(Booking, Int32))
      swaps.each do |swap|
        unless allocate(swap[:assign], swap[:space], throwaway, 0)
          logger.warn { "manual displacement: could not assign space #{swap[:space].id} to booking #{swap[:assign].id}" }
        end
      end
    end

    "manual displacement complete"
  rescue error
    logger.error(exception: error) { "manual displacement failed" }
    "manual displacement failed: #{error.message}"
  end

  # ===================================
  # Allocation core
  # ===================================

  # Bookings moved off a space this run, awaiting a "displaced" email. The email
  # is deferred to the end of the run so it's only sent to users who DON'T land
  # a new space the same run (a re-allocated booking gets an "approved" email
  # instead). Keyed by (booking id, instance); value is the booking + reason.
  @displaced_pending : Hash(Tuple(Int64, Int64?), Tuple(Booking, String)) = {} of Tuple(Int64, Int64?) => Tuple(Booking, String)

  # One preemption displacement decided this run: on `space`, `displaced` (email)
  # would be / was bumped so `replaced_with` (a higher-priority booking) could
  # take it. Recorded whether or not displacement is enabled.
  struct DisplacementRecord
    include JSON::Serializable

    getter starting : Int64 # parking date (epoch) — used to sort/group the report
    getter date : String    # the parking date, dd/mm/yyyy in the building timezone
    getter space : String   # the parking space NAME (identifier), not the asset id
    getter displaced : String
    getter replaced_with : String

    def initialize(@starting, @date, @space, @displaced, @replaced_with)
    end
  end

  # preemption displacement decisions this run (surfaced via the report + status)
  @displacement_report : Array(DisplacementRecord) = [] of DisplacementRecord

  protected def run_allocation
    # reset per-sync cardholder lookup error tracking
    @lookup_errors = [] of LookupError
    @failed_lookups = Set(String).new
    @no_card_bookings = {} of String => Booking
    @displaced_pending = {} of Tuple(Int64, Int64?) => Tuple(Booking, String)
    @displacement_report = [] of DisplacementRecord

    starting = Time.utc.to_unix
    # only allocate bookings up to the end of the upcoming Friday (local time)
    ending = next_friday_cutoff.to_unix

    # Fetch the world up front. If EITHER the spaces or the bookings query fails
    # we abort the whole run: proceeding with an empty/partial view would make
    # build_desired_access compute no desired grants and apply_access_changes
    # would then REVOKE everyone's parking access on a transient staff API
    # blip. Leaving @access_granted untouched lets the next sweep retry safely.
    begin
      spaces = parking_spaces
      bookings = fetch_bookings(starting, ending)
    rescue error
      logger.error(exception: error) { "aborting allocation run: staff API query failed — leaving existing access untouched" }
      return
    end

    spaces_by_id = spaces.each_with_object({} of String => ParkingSpace) { |s, h| h[s.id] = s }

    # Spaces that resolve to no Gallagher group can't grant access. Report them
    # (so the misconfiguration is visible) and exclude bookable ones from
    # allocation, so no booking is placed on a spot the user can't get into.
    unmapped_space_ids = report_spaces_without_groups(spaces)

    bookable_spaces = spaces.select { |s| s.bookable && s.assigned_to.presence.nil? && !unmapped_space_ids.includes?(s.id) }
    assigned_spaces = spaces.select { |s| s.assigned_to.presence }

    logger.debug { "allocation run: #{spaces.size} spaces total, #{bookable_spaces.size} bookable, #{assigned_spaces.size} permanently assigned, #{unmapped_space_ids.size} without a gallagher group" }
    logger.debug { "allocation run: processing #{bookings.size} active bookings" }

    # Calculate priority for each booking; the base group priority is cached
    # per-user across runs (@user_priority_cache, flushed daily / on config change)
    booking_meta = bookings.map do |booking|
      priority = priority_for(booking, @user_priority_cache)
      {booking, priority}
    end

    # Sort: priority desc, then created asc (older first)
    booking_meta.sort! do |a, b|
      cmp = b[1] <=> a[1]
      cmp == 0 ? (a[0].created || 0_i64) <=> (b[0].created || 0_i64) : cmp
    end

    # Track current allocations: asset_id => ALL bookings holding that asset.
    # The allocation window spans several days, so one space legitimately holds
    # multiple bookings (different days) — every one of them must be visible to
    # the busy/preemption checks or a new booking can be allocated on top of an
    # existing one (clashing bookings).
    current_allocations = {} of String => Array(Tuple(Booking, Int32))
    booking_meta.each do |(booking, priority)|
      # rejected/cancelled bookings may still carry an asset id — they don't
      # occupy the space (they'd block free spots and could be "displaced")
      next if booking.rejected || booking.deleted
      asset_id = booking.asset_ids.first?
      next if asset_id.nil? || asset_id.starts_with?("unallocated")
      (current_allocations[asset_id] ||= [] of Tuple(Booking, Int32)) << {booking, priority}
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

      # The space can no longer hold this booking — move it off so the second
      # pass re-allocates it to a usable space this run (or leaves it wait-listed
      # if none is free). displace_booking also resets process_state so the
      # re-allocation's "approved" email can fire. Two cases:
      #  - out of service (bookable=false, e.g. flooded): a FORCED move that
      #    happens even when allow_displacement is off — the space is gone.
      #  - no resolvable Gallagher group: respects the displacement policy (it
      #    may just be a config gap that gets fixed; the user can still park).
      out_of_service = !space.bookable
      if out_of_service || unmapped_space_ids.includes?(space.id)
        email_reason = out_of_service ? "The parking space was taken out of service." : "The parking space is no longer available."
        logger.warn { "booking #{booking.id} is on space #{space.id} (#{out_of_service ? "no longer bookable" : "no gallagher group"}); moving off it" }
        if displace_booking(booking, space, forced: out_of_service)
          register_displacement(booking, email_reason)
          remove_allocation(current_allocations, space.id, booking)
        end
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

    # Now that re-allocation has run, notify only the users still without a space
    flush_displaced_emails

    # log + surface the displacement report (works whether displacement is on or off)
    log_displacement_report

    # Compute desired gallagher access from the FINAL booking state, then diff
    # against @access_granted and apply only the additions/removals we own.
    desired_access = build_desired_access(booking_meta, spaces_by_id, assigned_spaces)
    apply_access_changes(desired_access)

    # surface cardholder lookup failures for reporting
    publish_lookup_errors

    # free the memory
    @lookup_errors = [] of LookupError
    @failed_lookups = Set(String).new
    @no_card_bookings = {} of String => Booking
    @displaced_pending = {} of Tuple(Int64, Int64?) => Tuple(Booking, String)
  end

  # Surface this run's cardholder lookup errors, reconcile the no-card list, and
  # notify newly-affected users. The no-card list is recomputed from scratch each
  # run (= the set of users we couldn't resolve), so users who have since been
  # issued a card drop off even if they didn't book again. We notify only users
  # who weren't already on the previous list (they've already had an email) and
  # only persist when the set actually changes (to minimise define_setting writes).
  protected def publish_lookup_errors : Nil
    logger.info { "allocation run: #{@lookup_errors.size} cardholder lookup error(s)" } unless @lookup_errors.empty?
    self[:lookup_error_count] = @lookup_errors.size
    self[:lookup_errors] = @lookup_errors

    previous = @no_card_mutex.synchronize { @no_card_users }

    # email each newly-unresolvable user once, with the reason from their error
    # (outside the mutex — the send is a blocking network call)
    notified = Set(String).new
    @lookup_errors.each do |error|
      next if previous.includes?(error.email)
      next unless notified.add?(error.email)
      if booking = @no_card_bookings[error.email]?
        send_no_card_email(booking, error.reason)
      end
    end

    updated = Set.new(@lookup_errors.map(&.email)).to_a
    self[:users_without_cards] = @no_card_mutex.synchronize do
      if updated.to_set != previous.to_set
        @no_card_users = updated
        persist_no_card_users
      end
      @no_card_users.dup
    end
  rescue error
    logger.warn(exception: error) { "failed to publish lookup errors" }
  end

  # 13:00 on the upcoming Friday in the configured timezone. On Sat/Sun this
  # rolls forward to the next week's Friday, and once Friday 13:00 has passed
  # it also rolls to the following Friday — otherwise the allocation window
  # would end in the past and nothing would be processed.
  protected def next_friday_cutoff : Time
    now = Time.local(@timezone)
    days_until_friday = (Time::DayOfWeek::Friday.value - now.day_of_week.value) % 7
    friday = now + days_until_friday.days
    cutoff = Time.local(friday.year, friday.month, friday.day, 13, 0, 0, location: @timezone)
    cutoff <= now ? cutoff.shift(days: 7) : cutoff
  end

  # Walk the final booking + permanent-assignment state and emit the gallagher
  # group memberships we want to be in place. Bookings whose asset_ids start
  # with "unallocated" are skipped (no allocated space => no access).
  protected def build_desired_access(
    booking_meta : Array(Tuple(Booking, Int32)),
    spaces_by_id : Hash(String, ParkingSpace),
    assigned_spaces : Array(ParkingSpace),
  ) : Hash(String, Hash(String, Grant))
    desired = {} of String => Hash(String, Grant)

    booking_meta.each do |(booking, _priority)|
      next if booking.rejected || booking.deleted
      asset_id = booking.asset_ids.first?
      next if asset_id.nil? || asset_id.starts_with?("unallocated")
      space = spaces_by_id[asset_id]?
      next unless space

      # time-bounded access: from a configurable margin before the booking
      # starts, until the booking ends
      until_unix = booking.booking_end
      from_unix = booking.booking_start - @access_minutes_before.to_i64 * 60
      record_desired_access(desired, booking.user_email, space, until_unix, from_unix)
    end

    assigned_spaces.each do |space|
      assignee = space.assigned_to
      next unless assignee && !assignee.empty?
      # permanent assignments are standing access, not a booking — no time window
      record_desired_access(desired, assignee, space, nil, nil)
    end

    desired
  end

  protected def record_desired_access(
    desired : Hash(String, Hash(String, Grant)),
    user_email : String,
    space : ParkingSpace,
    until_unix : Int64?,
    from_unix : Int64?,
  ) : Nil
    group_ids = gallagher_group_ids_for(space)
    if group_ids.empty?
      logger.warn { "no gallagher group configured for space #{space.id} (features: #{space.features})" }
      return
    end

    # nil means we could not resolve the user to a Gallagher cardholder; the
    # failure has already been logged + recorded for reporting
    cardholder_id = lookup_cardholder(user_email)
    return if cardholder_id.nil?

    email_key = user_email.downcase
    key = grant_key(email_key, until_unix)
    group_ids.each do |gid|
      bucket = desired[gid] ||= {} of String => Grant
      # Two bookings for the same user that map to the same group AND share an
      # end time collapse onto one grant key (we match/remove by until only).
      # Keep the EARLIEST start so the single granted window still spans both
      # bookings — otherwise the later start would deny entry during the gap.
      from = if existing = bucket[key]?
               earliest_from(existing.from_unix, from_unix)
             else
               from_unix
             end
      bucket[key] = Grant.new(email_key, cardholder_id, until_unix, from)
    end
  end

  # the earlier (smaller) of two optional start times; nil only when both nil
  protected def earliest_from(a : Int64?, b : Int64?) : Int64?
    return b if a.nil?
    return a if b.nil?
    Math.min(a, b)
  end

  # Diff desired against @access_granted (keyed by user email + access window):
  #  - grants no longer required have their access removed (matched by until)
  #  - new grants are added, unless the cardholder already holds that exact
  #    window (someone else granted it — we don't take responsibility for it)
  #  - grants present in both are left untouched
  # Booking grants are time-bounded (add with from/until); we match and remove
  # by until only so a changed access_minutes_before never orphans a grant.
  # Updates @access_granted with the resulting tracked state and persists it.
  protected def apply_access_changes(desired : Hash(String, Hash(String, Grant))) : Nil
    all_groups = (@access_granted.keys + desired.keys).uniq
    new_state = {} of String => Hash(String, Grant)

    all_groups.each do |group_id|
      new_grants = desired[group_id]? || {} of String => Grant
      old_grants = @access_granted[group_id]? || {} of String => Grant

      tracked = {} of String => Grant

      # remove grants we previously made but that are no longer required
      (old_grants.keys - new_grants.keys).each do |key|
        grant = old_grants[key]
        begin
          gallagher.zone_access_remove_member(group_id, grant.cardholder_id, nil, grant.until_unix).get
          logger.debug { "removed #{grant.email} from gallagher group #{group_id} (until #{grant.until_unix})" }
        rescue error
          logger.warn(exception: error) { "failed removing #{grant.email} from gallagher group #{group_id}" }
        end
      end

      # grants in both — already made by us, keep tracking, no API call
      (new_grants.keys & old_grants.keys).each do |key|
        tracked[key] = new_grants[key]
      end

      # new grants — add, but skip a cardholder already holding that window
      (new_grants.keys - old_grants.keys).each do |key|
        grant = new_grants[key]
        begin
          already_member = nil.as(JSON::Any::Type)
          begin
            already_member = gallagher.zone_access_member?(group_id, grant.cardholder_id, nil, grant.until_unix).get.raw
          rescue
            already_member = nil
          end

          if already_member
            logger.debug { "#{grant.email} already has access to gallagher group #{group_id} (until #{grant.until_unix}), leaving untouched" }
            next
          end

          gallagher.zone_access_add_member(group_id, grant.cardholder_id, grant.from_unix, grant.until_unix).get
          tracked[key] = grant
          logger.debug { "granted #{grant.email} access to gallagher group #{group_id} (from #{grant.from_unix} until #{grant.until_unix})" }
        rescue error
          logger.warn(exception: error) { "failed adding #{grant.email} to gallagher group #{group_id}" }
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

  # Raises on failure: callers must treat a failed fetch as "unknown", NOT as
  # "no bookings" — an empty list would let the run revoke all access (see
  # run_allocation).
  protected def fetch_bookings(starting : Int64, ending : Int64) : Array(Booking)
    Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: [building_id],
      period_start: starting,
      period_end: ending,
      limit: 100,
    ).get_json)
  rescue error
    logger.error(exception: error) { "failed to query parking bookings" }
    raise error
  end

  # Active (non-rejected/deleted) parking bookings for a user that START at
  # `start_time`, in this building. Used by manual_displacement.
  protected def bookings_for(email : String, start_time : Int64) : Array(Booking)
    Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: [building_id],
      email: email,
      period_start: start_time,
      period_end: start_time + 1,
    ).get_json).select { |b| b.booking_start == start_time && !b.rejected && !b.deleted }
  rescue error
    logger.error(exception: error) { "failed to query bookings for #{email}" }
    [] of Booking
  end

  # Create a wait-list parking booking for `assign_email` mirroring `template`
  # (same time, zones and extension_data) with the assignee's user details. The
  # asset is a placeholder until the booking is assigned a real space.
  protected def create_manual_booking(template : Booking, assign_email : String) : Booking?
    user = ::PlaceCalendar::User.from_json(calendar.get_user(assign_email, additional_fields: @directory_lookup_fields).get_json)
    placeholder = "unallocated-manual-#{template.id}"
    created = staff_api.create_booking(
      booking_type: BOOKING_TYPE,
      asset_id: placeholder,
      asset_ids: [placeholder],
      user_id: assign_email,
      user_email: assign_email,
      user_name: user.name.presence || assign_email,
      zones: template.zones,
      booking_start: template.booking_start,
      booking_end: template.booking_end,
      approved: false,
      process_state: "wait_list",
      extension_data: JSON::Any.new(template.extension_data),
    ).get_json
    Booking.from_json(created)
  rescue error
    logger.error(exception: error) { "failed to create wait-list booking for #{assign_email}" }
    nil
  end

  # ===================================
  # Priority calculation
  # ===================================

  # user_email (downcased) => base group priority. Persists across sync runs
  # (group_priority does a per-user directory lookup) and is flushed once a day
  # (see on_update) so AD group changes are picked up.
  @user_priority_cache : Hash(String, Int32) = {} of String => Int32

  protected def clear_priority_cache : Nil
    logger.debug { "clearing user priority cache (#{@user_priority_cache.size} entries)" }
    @user_priority_cache = {} of String => Int32
  end

  # higher number = higher priority. 0 is "default staff".
  protected def priority_for(booking : Booking, cache : Hash(String, Int32)) : Int32
    user_email = booking.user_email.downcase
    base = cache[user_email]?
    if base.nil?
      # cache successful lookups ONLY (mirroring lookup_cardholder): a failed
      # group lookup returns nil, and caching that as 0 would pin a top-group
      # user to the bottom of the allocation order until the next cache flush
      # (up to a day). Treat the failure as 0 for THIS run only and retry the
      # lookup next sweep.
      if resolved = group_priority(user_email)
        cache[user_email] = resolved
        base = resolved
      else
        base = 0
      end
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

  # The user's group priority, or nil when the directory lookup FAILED — the
  # caller must not cache nil ("unknown" is not the same as "in no groups").
  # Accurate priority is important, so a failing lookup is retried with
  # exponential backoff (@group_lookup_retries times, @group_lookup_backoff up to
  # @group_lookup_max_backoff) before the error propagates to the rescue -> nil.
  protected def group_priority(user_email : String) : Int32?
    return 0 if @auto_approval_groups.empty?

    groups = SimpleRetry.try_to(
      # +1: the initial attempt plus @group_lookup_retries retries
      max_attempts: @group_lookup_retries + 1,
      base_interval: @group_lookup_backoff,
      max_interval: @group_lookup_max_backoff,
    ) do |attempt, last_error|
      logger.warn(exception: last_error) { "retrying group lookup for #{user_email} (attempt #{attempt})" } if last_error
      calendar.get_groups(user_email).get.as_a
    end

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
    logger.warn(exception: error) { "failed to lookup groups for #{user_email} after #{@group_lookup_retries} retries" }
    nil
  end

  # ===================================
  # Already-allocated bookings
  # ===================================

  protected def handle_allocated_booking(booking : Booking, space : ParkingSpace) : Nil
    # fully done: access granted AND the approval email has been sent
    return if booking.process_state == "access_granted_emailed"
    # access was granted on an earlier pass but the approval email hasn't been
    # confirmed sent (a previous send failed) — just (re)send it, no re-approval
    return approved_email(booking, space) if booking.process_state == "access_granted"

    # withhold approval until the user can actually be granted Gallagher access
    return unless ensure_user_has_card(booking)

    logger.debug { "approval/email for already-allocated booking #{booking.id} (#{booking.user_email}) on space #{space.id}" }

    # If the booking has not been approved yet, approve it (persisted
    # per-instance for recurring bookings)
    unless booking.approved
      begin
        staff_api.approve(booking.id, booking.instance).get
        booking.approved = true
      rescue error
        logger.warn(exception: error) { "failed to approve booking #{booking.id}" }
      end
    end

    # persist that access is granted BEFORE attempting the email so a failed
    # send is retried (email-only) next pass rather than re-running the grant
    update_state(booking, "access_granted")
    approved_email(booking, space)
  rescue error
    logger.error(exception: error) { "failed to process allocated booking #{booking.id}" }
  end

  # ===================================
  # Unallocated bookings
  # ===================================

  # a booking created more than this long ago is "stale" once its start has
  # passed (see stale_waitlist?)
  STALE_WAITLIST_GRACE = 3_i64 * 3600

  # A wait-listed booking that already STARTED and was CREATED more than 3 hours
  # ago is for a meeting that has effectively passed. Trying to allocate it now
  # risks clashing with bookings on the space that have since ended but whose
  # (past) window still overlaps this booking's — so we leave it alone. A booking
  # created recently (e.g. a same-day/walk-in request) is still allocated even if
  # its start is just in the past.
  protected def stale_waitlist?(booking : Booking) : Bool
    now = Time.utc.to_unix
    return false unless booking.booking_start < now
    created = booking.created
    !created.nil? && created < now - STALE_WAITLIST_GRACE
  end

  protected def handle_unallocated_booking(
    booking : Booking,
    priority : Int32,
    bookable_spaces : Array(ParkingSpace),
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
  ) : Nil
    # don't try to allocate a stale wait-listed booking — see stale_waitlist?
    if stale_waitlist?(booking)
      logger.debug { "skipping stale wait-listed booking #{booking.id} (started in the past, created over 3h ago)" }
      return
    end

    # withhold allocation until the user can actually be granted Gallagher access
    return unless ensure_user_has_card(booking)

    request_type = booking.extension_data["request_type"]?.try(&.as_s?)

    # After hours bookings cannot be auto-approved
    if request_type == "after_hours" && !booking.approved
      logger.debug { "booking #{booking.id} requires manual approval (after hours)" }
      waiting_approval_email(booking)
      return
    end

    compatible = prioritise_spaces(compatible_spaces(booking, bookable_spaces), booking)

    # Filter out spaces in-use during this booking's window. Each instance of a
    # recurring booking is allocated independently (booking_instances persist a
    # per-instance asset override), so a series can split across spaces on
    # busy days.
    busy_assets = busy_asset_ids_during(booking, current_allocations)
    available = compatible.reject { |s| busy_assets.includes?(s.id) }

    # Restriction requests (ACROD etc.) are best-effort: when no matching space
    # is free the restriction is ignored and a regular space provided instead.
    # Height requirements are ALWAYS enforced — they never fall back.
    if available.empty? && exclusive_request?(booking)
      logger.debug { "no restricted spaces available for booking #{booking.id}; falling back to regular spaces" }
      compatible = prioritise_spaces(compatible_spaces(booking, bookable_spaces, ignore_exclusive: true), booking)
      available = compatible.reject { |s| busy_assets.includes?(s.id) }
    end

    if compatible.empty?
      logger.warn { "no compatible spaces for booking #{booking.id} (vehicle/restriction filter)" }
      wait_list_email(booking)
      return
    end

    # Try the free spaces in preference order. allocate marks any space the
    # server rejects as clashing (busy) and returns false, so we just move on to
    # the next candidate — preventing the "allocated onto an already-booked
    # space" failures our zone-scoped busy view can't predict.
    available.each do |space|
      return if allocate(booking, space, current_allocations, priority)
    end

    # No free space — find the preemption target: a compatible space whose
    # overlapping occupants are ALL lower priority and displaceable now (none
    # within their notice period). This is computed even when displacement is
    # DISABLED, so the end-of-run displacement report can show management which
    # displacements would occur if it were enabled. Choosing the space whose
    # highest overlapping priority is lowest displaces the least-privileged
    # users; bumping a mid-priority user would let them, in turn, preempt someone
    # below them, cascading displacements in a single run.
    candidates = compatible.compact_map do |space|
      occupants = current_allocations[space.id]?
      next unless occupants
      conflicts = occupants.select { |(other, _other_priority)| bookings_overlap?(booking, other) }
      next if conflicts.empty?
      next unless conflicts.all? { |(_other, other_priority)| other_priority < priority }
      # all overlapping occupants must be displaceable now (none within their
      # notice period) for the space to be freed
      next unless conflicts.all? { |(other, _other_priority)| !within_displacement_notice?(other) }
      {space, conflicts}
    end

    # lowest (max) occupant priority wins; ties keep allocation-preference order
    # (compatible is already sorted by zone then height, and min_by? returns the
    # first minimum)
    target = candidates.min_by? { |(_space, conflicts)| conflicts.max_of { |(_other, other_priority)| other_priority } }

    unless target
      logger.debug { "no preemption candidate for booking #{booking.id}, sending wait list email" }
      wait_list_email(booking)
      return
    end

    target_space, conflicts = target
    # record the displacement decision for the report — whether or not we act on it
    conflicts.each { |(conflict_booking, _p)| record_displacement(target_space, conflict_booking, booking) }

    # displacement trial: when disabled, the would-be displacement is captured in
    # the report above but never acted on — the booking waits for a space instead.
    unless @allow_displacement
      logger.debug { "displacement disabled; booking #{booking.id} would preempt space #{target_space.id}, sending wait list email" }
      # Mirror, in our LOCAL view only, what an enabled run would do to
      # current_allocations: the occupant moves off and this (higher priority)
      # booking takes the space. Without this every later would-be preemptor
      # keeps picking the same unchanged occupant/space, so the report repeats
      # one space instead of cascading across the spaces it actually would.
      conflicts.each { |(conflict_booking, _p)| remove_allocation(current_allocations, target_space.id, conflict_booking) }
      (current_allocations[target_space.id] ||= [] of Tuple(Booking, Int32)) << {booking, priority}
      wait_list_email(booking)
      return
    end

    # The space must be fully freed BEFORE we allocate over it — a failed
    # displacement means the occupant still holds the space server-side and
    # allocating would create clashing bookings. Displaced users are NOT notified
    # yet: if the preemption can't complete, the moves are rolled back invisibly
    # instead of churning displaced/approved emails.
    displaced = [] of Tuple(Booking, Int32)
    freed = true
    conflicts.each do |(conflict_booking, conflict_priority)|
      logger.info { "preempting booking #{conflict_booking.id} (priority #{conflict_priority}) for higher priority booking #{booking.id} (priority #{priority})" }
      if displace_booking(conflict_booking, target_space)
        remove_allocation(current_allocations, target_space.id, conflict_booking)
        displaced << {conflict_booking, conflict_priority}
      else
        # don't displace further users for a preemption that can't proceed
        freed = false
        break
      end
    end

    # allocate can still fail (e.g. the freed space has another occupant our
    # zone-scoped view never saw); only notify the displaced users once the
    # preemption actually sticks
    allocated = freed && allocate(booking, target_space, current_allocations, priority)
    if allocated
      displaced.each { |(displaced_booking, _p)| register_displacement(displaced_booking, "The parking space was reassigned to a higher priority booking.") }
    else
      logger.warn { "could not move booking #{booking.id} onto space #{target_space.id}; restoring #{displaced.size} displaced booking(s)" }
      displaced.each do |(displaced_booking, displaced_priority)|
        restore_allocation(displaced_booking, displaced_priority, target_space, current_allocations)
      end
      wait_list_email(booking)
    end
  rescue error
    logger.error(exception: error) { "failed to process unallocated booking #{booking.id}" }
  end

  # Record one preemption displacement decision (grouped/logged at end of run).
  protected def record_displacement(space : ParkingSpace, displaced_booking : Booking, new_booking : Booking) : Nil
    starting = new_booking.booking_start
    date = Time.unix(starting).in(@timezone).to_s("%d/%m/%Y")
    name = space.identifier.presence || space.id
    @displacement_report << DisplacementRecord.new(starting, date, name, displaced_booking.user_email, new_booking.user_email)
  end

  # Log (and surface as status) the displacements decided this run, grouped by
  # parking date. Emitted whether displacement is enabled (these happened) or
  # disabled (these WOULD happen) so management can review the impact.
  protected def log_displacement_report : Nil
    sorted = @displacement_report.sort_by(&.starting)
    self[:displacement_report] = sorted
    return if sorted.empty?

    blocks = sorted.group_by(&.date).map do |date, records|
      lines = records.map { |r| "* space #{r.space} displaced #{r.displaced} with #{r.replaced_with}" }
      "#{date}\n#{lines.join('\n')}"
    end

    mode = @allow_displacement ? "enabled" : "disabled"
    logger.info { "Displacement report (displacement #{mode}):\n\n#{blocks.join("\n\n")}" }
  rescue error
    logger.warn(exception: error) { "failed to log displacement report" }
  end

  # Remove one booking instance from an asset's tracked allocations (after
  # displacement). Instances of a recurring booking are independent — each has
  # its own persisted asset override — so match on (id, instance).
  protected def remove_allocation(
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
    asset_id : String,
    booking : Booking,
  ) : Nil
    return unless occupants = current_allocations[asset_id]?
    occupants.reject! { |(other, _)| other.id == booking.id && other.instance == booking.instance }
    current_allocations.delete(asset_id) if occupants.empty?
  end

  # Find assets in-use at the same time as `booking` — an asset is busy if ANY
  # of the bookings holding it overlaps the requested window
  protected def busy_asset_ids_during(
    booking : Booking,
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
  ) : Set(String)
    busy = Set(String).new
    current_allocations.each do |asset_id, occupants|
      overlapping = occupants.any? do |(other, _other_priority)|
        next false if other.id == booking.id && other.instance == booking.instance
        bookings_overlap?(booking, other)
      end
      busy << asset_id if overlapping
    end
    busy
  end

  protected def bookings_overlap?(a : Booking, b : Booking) : Bool
    a.booking_start < b.booking_end && b.booking_start < a.booking_end
  end

  # ===================================
  # Compatibility filter
  # ===================================

  # Does the booking request a restriction feature (ACROD, Small car only, ...)
  # rather than a height class? These are best-effort and may fall back to a
  # regular space; height requirements never do.
  protected def exclusive_request?(booking : Booking) : Bool
    restriction_id = booking.extension_data["space_restrictions"]?.try(&.as_i64?)
    return false unless restriction_id
    return false unless name = @restriction_lookup[restriction_id]?
    !@height_features.includes?(name)
  end

  protected def compatible_spaces(booking : Booking, spaces : Array(ParkingSpace), ignore_exclusive : Bool = false) : Array(ParkingSpace)
    vehicle = VehicleType.parse_request(booking.extension_data["vehicle_type"]?.try(&.as_s?))

    restriction_id = booking.extension_data["space_restrictions"]?.try(&.as_i64?)
    restriction_name = restriction_id ? @restriction_lookup[restriction_id]? : nil
    req_height = restriction_name ? @height_features.index(restriction_name) : nil

    # a restriction request may be ignored (regular-space fallback) — a height
    # requirement is never dropped
    restriction_name = nil if ignore_exclusive && req_height.nil?

    spaces.select do |space|
      vehicle_ok = vehicle.nil? || vehicle.matches_notes?(space.notes)

      restriction_ok = if req_height
                         # height restriction: a space accommodates the booking
                         # when its max height is equal to OR greater than the
                         # requested one (heights are ranked by id order)
                         sh = space_height_index(space)
                         if sh
                           sh >= req_height
                         else
                           logger.warn { "space #{space.identifier} (#{space.id}) has no height indicator" }
                           false
                         end
                       elsif restriction_name
                         # exclusive restriction (ACROD, Small car only): exact match
                         space.features.includes?(restriction_name)
                       else
                         # no restriction: avoid exclusive-only spaces
                         (space.features & @exclusive_features).empty?
                       end

      vehicle_ok && restriction_ok
    end
  end

  # The space's max height rank (highest "Max height" feature it carries), or nil
  # if the space has no height feature.
  protected def space_height_index(space : ParkingSpace) : Int32?
    space.features.compact_map { |feature| @height_features.index(feature) }.max?
  end

  # Order candidate spaces best-first: configured zone/feature preference first,
  # then the SMALLEST height (a space with no height feature sorts last). Handing
  # out the shortest space that works keeps taller spaces for taller vehicles —
  # this applies to standard cars too, not just height-restricted bookings. For
  # a height-restricted booking the candidates are already filtered to a height
  # >= the requested one, so "smallest height" is the closest fit.
  # Overall allocation order: user priority (booking order) -> zone -> height.
  protected def prioritise_spaces(spaces : Array(ParkingSpace), booking : Booking) : Array(ParkingSpace)
    vehicle = VehicleType.parse_request(booking.extension_data["vehicle_type"]?.try(&.as_s?))
    priority_features = case vehicle
                        when VehicleType::Bike
                          @bike_zone_priority
                        else
                          @car_zone_priority
                        end

    spaces.sort_by do |space|
      # primary: configured zone/feature preference
      zone_index = Int32::MAX
      priority_features.each_with_index do |feature, i|
        if space.features.includes?(feature)
          zone_index = i
          break
        end
      end

      # secondary: smallest height first (a space with no height feature sorts last)
      height_key = space_height_index(space) || Int32::MAX

      {zone_index, height_key}
    end
  end

  # ===================================
  # Allocate / displace / approve
  # ===================================

  # Returns true when the booking was placed on the space. The staff API is the
  # source of truth for clashes: our busy view is built from bookings scoped to
  # the building zone (and capped by the fetch limit), so a space can look free
  # to us yet already be booked server-side. A rejected update is therefore not
  # an error — the space is taken, so we mark it busy and the caller tries the
  # next candidate.
  protected def allocate(
    booking : Booking,
    space : ParkingSpace,
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
    priority : Int32,
  ) : Bool
    logger.debug { "allocating booking #{booking.id} -> space #{space.id}" }

    # booking_instances persist per-instance asset overrides (nil inherits the
    # parent), so a recurring instance is allocated independently of its
    # siblings — the instance arg routes the update to the override row.
    # use get_json where we don't care about the response data
    # it will still raise if there is an error but not waste CPU
    # on parsing the JSON payload
    begin
      booking.extension_data["location"] = JSON::Any.new(space.identifier || space.id)
      staff_api.update_booking(
        booking_id: booking.id,
        asset_id: space.id,
        instance: booking.instance,
        extension_data: booking.extension_data,
        zones: space.zones,
      ).get_json
    rescue error
      if clash_error?(error)
        logger.warn { "space #{space.id} is already booked for booking #{booking.id} (server clash); trying another space" }
        mark_clashed(current_allocations, space, booking)
      else
        logger.error(exception: error) { "failed to allocate booking #{booking.id} to space #{space.id}" }
      end
      return false
    end

    # only reflect the allocation locally once the API accepted it — the local
    # booking state feeds the busy checks and the end-of-run Gallagher access
    # reconciliation, so a failed update must not look like a held space (or
    # grant access to a space the booking never got)
    booking.asset_id = space.id
    booking.asset_ids = [space.id]
    (current_allocations[space.id] ||= [] of Tuple(Booking, Int32)) << {booking, priority}

    # update succeeded so the space is ours — approval/email failures don't undo
    # the allocation (the next sweep's first pass re-approves/re-emails)
    begin
      # approval is also persisted per instance
      staff_api.approve(booking.id, booking.instance).get
      booking.approved = true
    rescue error
      logger.warn(exception: error) { "failed to approve booking #{booking.id}" }
    end

    # mark access granted before emailing: if the email send fails the booking
    # stays "access_granted" and the next pass retries the email only
    update_state(booking, "access_granted")
    approved_email(booking, space)
    true
  end

  # Booking id used for a "phantom" occupant inserted when the server rejects an
  # allocation as clashing. It records the (otherwise invisible) occupant so the
  # busy check and preemption skip the space for the rest of the run. Negative
  # so it never matches a real booking id.
  CLASH_PHANTOM_ID = -1_i64

  # Does this error represent the staff API rejecting an update because the
  # space is already booked (HTTP 409 / "Conflicting booking")?
  protected def clash_error?(error : Exception) : Bool
    message = error.message || ""
    message.includes?("409") || message.downcase.includes?("conflict")
  end

  # Mark a space the server reported as already booked for `booking`'s window so
  # neither the busy check nor preemption offers it again this run. We never saw
  # the real occupant, so use a non-displaceable (max priority) phantom carrying
  # this booking's window — it only blocks bookings that overlap that window.
  protected def mark_clashed(
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
    space : ParkingSpace,
    booking : Booking,
  ) : Nil
    phantom = booking.dup
    phantom.id = CLASH_PHANTOM_ID
    (current_allocations[space.id] ||= [] of Tuple(Booking, Int32)) << {phantom, Int32::MAX}
  end

  # Move a booking off its space on the staff API. Returns true when the
  # booking no longer holds the space; on failure the local booking state is
  # left holding the space (matching the server), so the busy checks and access
  # reconciliation still see it as occupied — callers must NOT allocate over it.
  #
  # Does NOT notify or reset process_state: callers confirm the displacement is
  # final (e.g. the preempting allocate succeeded) and then call
  # register_displacement (deferred email) — or roll the move back with
  # restore_allocation without the user ever having been emailed.
  # `forced` displacements happen even when allow_displacement is off: the
  # allow_displacement policy only governs PREEMPTION (bumping a lower-priority
  # user). When a space can no longer hold the booking at all (out of service),
  # the move is involuntary and must always proceed.
  # True when the booking starts too soon to be (non-forced) displaced: users
  # are given `displacement_notification_hours` of notice. Forced moves (a space
  # taken out of service) ignore this — the space is gone regardless.
  protected def within_displacement_notice?(booking : Booking) : Bool
    return false if @displacement_notification_hours <= 0
    booking.booking_start < Time.utc.to_unix + @displacement_notification_hours.to_i64 * 3600
  end

  protected def displace_booking(booking : Booking, space : ParkingSpace, forced : Bool = false) : Bool
    unless forced
      unless @allow_displacement
        logger.info { "displacement disabled; leaving booking #{booking.id} on space #{space.id}" }
        return false
      end
      if within_displacement_notice?(booking)
        logger.info { "booking #{booking.id} starts within the #{@displacement_notification_hours}h displacement notice period; not displacing" }
        return false
      end
    end

    logger.info { "displacing booking #{booking.id} (#{booking.user_email}) from space #{space.id}" }

    placeholder = "unallocated-displaced-#{booking.id}"

    begin
      # per-instance: only this occurrence moves off the space; other instances
      # of a recurring booking keep their own asset overrides
      staff_api.update_booking(
        booking_id: booking.id,
        asset_id: placeholder,
        instance: booking.instance,
      ).get_json
    rescue error
      logger.warn(exception: error) { "failed to move booking #{booking.id} off space #{space.id}; leaving the allocation in place" }
      return false
    end

    booking.asset_id = placeholder
    booking.asset_ids = [placeholder]
    true
  rescue error
    logger.error(exception: error) { "failed to displace booking #{booking.id}" }
    false
  end

  # Record that `booking` was moved off its space, with the reason to show the
  # user. Resets process_state to "wait_list" immediately (so a re-allocation's
  # approved email can fire, and a mailer failure can't leave a stale
  # access_granted), but DEFERS the displaced email — see flush_displaced_emails.
  protected def register_displacement(booking : Booking, reason : String) : Nil
    update_state(booking, "wait_list")
    @displaced_pending[{booking.id, booking.instance}] = {booking, reason}
  end

  # Send the deferred displaced emails — but skip any booking that landed a new
  # space this run (its "approved" email already covers the change).
  protected def flush_displaced_emails : Nil
    @displaced_pending.each_value do |(booking, reason)|
      asset_id = booking.asset_ids.first?
      next if asset_id && !asset_id.starts_with?("unallocated")
      displaced_email(booking, reason)
    end
  end

  # Undo a not-yet-finalised displacement: put the booking back on its space
  # (server + local + tracking). No emails were sent, so a successful restore is
  # invisible to the user. If the restore itself fails the booking is left
  # unallocated and the remainder of this pass (or the next sweep) re-allocates.
  protected def restore_allocation(
    booking : Booking,
    priority : Int32,
    space : ParkingSpace,
    current_allocations : Hash(String, Array(Tuple(Booking, Int32))),
  ) : Nil
    # per-instance, matching displace_booking
    booking.extension_data["location"] = JSON::Any.new(space.identifier || space.id)
    staff_api.update_booking(
      booking_id: booking.id,
      asset_id: space.id,
      instance: booking.instance,
      extension_data: booking.extension_data
    ).get_json

    booking.asset_id = space.id
    booking.asset_ids = [space.id]
    (current_allocations[space.id] ||= [] of Tuple(Booking, Int32)) << {booking, priority}
  rescue error
    logger.warn(exception: error) { "failed to restore booking #{booking.id} to space #{space.id}; leaving unallocated for re-allocation" }
  end

  # ===================================
  # Gallagher access management
  # ===================================

  # The Gallagher access groups a space belongs to: a per-asset
  # security_system_groups override if present, otherwise resolved by matching
  # the space's FEATURES against the `parking_areas` mapping (feature name =>
  # gallagher access group / zone id).
  protected def gallagher_group_ids_for(space : ParkingSpace) : Array(String)
    return space.security_system_groups.dup unless space.security_system_groups.empty?
    space.features.compact_map { |feature| @parking_areas[feature]? }.uniq!
  end

  # A parking space that resolves to no Gallagher group (so access can't be
  # granted for it). Surfaced via the :spaces_without_groups status for the
  # misconfiguration to be fixed.
  struct SpaceReport
    include JSON::Serializable

    getter id : String

    @[JSON::Field(emit_null: true)]
    getter identifier : String?

    getter features : Array(String)

    def initialize(@id, @identifier, @features)
    end
  end

  # Publish (as status) the spaces with no resolvable Gallagher group and return
  # the set of their ids so the run can exclude/skip them. Recomputed each run,
  # so a space drops off the report as soon as its mapping exists.
  protected def report_spaces_without_groups(spaces : Array(ParkingSpace)) : Set(String)
    unmapped = spaces.select { |space| gallagher_group_ids_for(space).empty? }
    unless unmapped.empty?
      logger.warn { "#{unmapped.size} parking space(s) have no gallagher group: #{unmapped.map(&.id)}" }
    end
    begin
      self[:spaces_without_groups] = unmapped.map { |space| SpaceReport.new(space.id, space.identifier, space.features) }
      self[:spaces_without_group_count] = unmapped.size
    rescue error
      logger.warn(exception: error) { "failed to publish spaces_without_groups status" }
    end
    unmapped.map(&.id).to_set
  end

  # user_email (downcased) => cardholder_id; only successful lookups are cached.
  # Persists across sync runs (directory + Gallagher lookups are expensive) and
  # is flushed once a day (see on_update) so a freshly-issued card is picked up.
  @cardholder_cache : Hash(String, String | Int64) = {} of String => String | Int64

  protected def clear_cardholder_cache : Nil
    logger.debug { "clearing cardholder lookup cache (#{@cardholder_cache.size} entries)" }
    @cardholder_cache = {} of String => String | Int64
  end

  protected def lookup_cardholder(user_email : String) : String | Int64 | Nil
    user_email = user_email.downcase
    if cached = @cardholder_cache[user_email]?
      return cached
    end
    # already failed (and recorded) earlier in this sync — don't retry/re-record
    return nil if @failed_lookups.includes?(user_email)

    # value we query Gallagher with: the resolved directory id (e.g. employeeId)
    # when configured, otherwise the email itself
    lookup_value = gallagher_lookup_value(user_email)
    if lookup_value.nil?
      @failed_lookups << user_email
      return nil
    end

    id_raw = gallagher.card_holder_id_lookup(lookup_value).get
    # a blank string id is not a valid grant target — treat it as "no card"
    id = id_raw.as_s?.presence || id_raw.as_i64?
    if id.nil?
      # the user has no card in Gallagher
      logger.warn { "no gallagher cardholder for #{user_email} (lookup: #{lookup_value})" }
      employee_id = @gallagher_id_field ? lookup_value : nil
      record_lookup_error(user_email, employee_id, "no gallagher cardholder found")
      @failed_lookups << user_email
      return nil
    end

    @cardholder_cache[user_email] = id
    id
  rescue error
    logger.warn(exception: error) { "cardholder lookup failed for #{user_email}" }
    record_lookup_error(user_email, nil, "cardholder lookup error: #{error.message}")
    @failed_lookups << user_email
    nil
  end

  # Guard used by the allocation passes: returns true when the user has a
  # Gallagher card (so the booking may be approved/allocated). When false the
  # booking is withheld; the lookup error is recorded (see lookup_cardholder) and
  # the no-card notification is handled at the end of the run (publish_lookup_errors).
  protected def ensure_user_has_card(booking : Booking) : Bool
    return true if lookup_cardholder(booking.user_email)
    # remember a booking for this user so the no-card email has booking context
    @no_card_bookings[booking.user_email.downcase] ||= booking
    false
  end

  # Notify a user (once per run reconciliation) that no Gallagher access card
  # could be found for them, including the reason from their lookup error.
  protected def send_no_card_email(booking : Booking, reason : String) : Nil
    logger.info { "withholding parking for #{booking.user_email}: #{reason}" }
    mailer.send_template(
      booking.user_email,
      {"parking_request", "no_card"},
      common_template_args(booking).merge({reason: reason}),
    ).get_json
  rescue error
    logger.warn(exception: error) { "failed to notify no-card user #{booking.user_email}" }
  end

  # caller must hold @no_card_mutex
  protected def persist_no_card_users : Nil
    define_setting(:users_without_cards, @no_card_users)
  rescue error
    logger.warn(exception: error) { "failed to persist users_without_cards setting" }
  end

  # The value used to query Gallagher for a cardholder id. With a directory id
  # field configured we look the user up in the directory (MS Graph) and read
  # that field from `unmapped`; otherwise the email is used directly. Returns
  # nil (recording an error) when a configured directory field can't be resolved.
  protected def gallagher_lookup_value(user_email : String) : String?
    field = @gallagher_id_field
    return user_email if field.nil?

    user_json = calendar.get_user(user_email, additional_fields: @directory_lookup_fields).get_json
    user = ::PlaceCalendar::User.from_json(user_json)
    value = unmapped_value(user.unmapped, field)

    if value.nil? || value.empty?
      logger.warn { "no '#{field}' directory field for #{user_email}" }
      record_lookup_error(user_email, nil, "directory field '#{field}' not found for user")
      return nil
    end
    value
  rescue error
    logger.warn(exception: error) { "directory lookup failed for #{user_email}" }
    record_lookup_error(user_email, nil, "directory lookup failed: #{error.message}")
    nil
  end

  # Read a value from `unmapped`, tolerating MS Graph casing differences (a
  # requested "employeeid" is returned as "employeeId"). Numeric ids are
  # stringified so a field surfaced as a JSON number is still usable.
  protected def unmapped_value(unmapped : Hash(String, JSON::Any)?, field : String) : String?
    return nil unless unmapped
    raw = unmapped[field]?
    if raw.nil?
      down = field.downcase
      if entry = unmapped.find { |(key, _value)| key.downcase == down }
        raw = entry[1]
      end
    end
    return nil if raw.nil?

    case value = raw.raw
    when String then value.presence
    when Int    then value.to_s
    when Float  then value.to_i64.to_s
    else             nil
    end
  end

  protected def record_lookup_error(email : String, employee_id : String?, reason : String) : Nil
    @lookup_errors << LookupError.new(email, employee_id, reason)
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

    # The generic approval template is always advertised: it is the fallback for
    # spaces whose granted group is not a parking_areas area (e.g. a per-asset
    # security_system_groups override) and #approved_email sends it when
    # approval_group_id returns nil.
    approved_templates = [
      TemplateFields.new(
        trigger: {"parking_request", "approved"},
        name: "Parking Approved",
        description: "Notifies the recipient that their parking is approved and access has been granted",
        fields: common_fields
      ),
    ]

    # Plus one approval template per Gallagher access group referenced by
    # `parking_areas`, so each parking area can have a distinct approval email.
    # The trigger embeds the group id (matching #approved_email); the description
    # is prefixed with the FIRST feature name mapping to that group.
    @parking_areas.values.uniq.each do |group_id|
      feature_name = @parking_areas.key_for?(group_id) || group_id
      approved_templates << TemplateFields.new(
        trigger: {"parking_request", "approved_#{group_id}"},
        name: "Parking Approved - #{feature_name}",
        description: "Approval for #{feature_name} - Notifies the recipient that their parking is approved and access has been granted",
        fields: common_fields
      )
    end

    approved_templates + [
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
        fields: common_fields + [{name: "reason", description: "the reason for displacement"}]
      ),
      TemplateFields.new(
        trigger: {"parking_request", "cancelled"},
        name: "Parking Cancelled",
        description: "Notifies the recipient that their parking booking was cancelled and access removed (includes a calendar cancellation)",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "rejected"},
        name: "Parking Rejected",
        description: "Notifies the recipient that their parking booking has been rejected",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "no_card"},
        name: "Parking No Access Card",
        description: "Notifies the recipient that their parking can't be set up because no Gallagher access card (or employee id) was found for them — sent once until they have a card",
        fields: common_fields + [{name: "reason", description: "the reason a Gallagher cardholder could not be resolved"}]
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

  # The Gallagher group id whose per-area approval template should be used for
  # this space, or nil to use the generic "approved" template. Derived from the
  # SAME resolved access groups as the grant (#gallagher_group_ids_for) so the
  # email never describes a group the user wasn't granted, and chosen by
  # `parking_areas` configuration order so the choice is deterministic when a
  # space spans multiple areas. A space granted only via a per-asset
  # security_system_groups override resolves to no parking_areas group and so
  # returns nil (generic template) — template_fields can't advertise a per-area
  # template for override groups, which live on the asset and aren't known here.
  protected def approval_group_id(space : ParkingSpace) : String?
    granted = gallagher_group_ids_for(space)
    @parking_areas.values.find { |group_id| granted.includes?(group_id) }
  end

  # ===================================
  # Calendar invite (.ics)
  # ===================================

  alias Attachment = PlaceOS::Driver::Interface::Mailer::Attachment

  ICS_METHOD_REQUEST = "REQUEST"
  ICS_METHOD_CANCEL  = "CANCEL"

  # A base64-encoded iCalendar (.ics) attachment for a parking email, or an empty
  # array when invites are disabled (no organizer configured). Naming the file
  # `.ics` makes the mailer emit a `text/calendar` MIME part, which clients
  # recognise as a calendar invite. Because the UID is stable per booking, the
  # REQUEST sent with the approval email and the CANCEL sent on displacement act
  # on the SAME calendar entry — a reassigned space is removed from the user's
  # calendar rather than duplicated.
  protected def calendar_attachment(booking : Booking, space_label : String?, cancel : Bool) : Array(Attachment)
    return [] of Attachment if @calendar_invite_from.nil?
    ics = parking_invite_ics(booking, space_label, cancel)
    [Attachment.new(file_name: "parking.ics", content: Base64.strict_encode(ics))]
  end

  # Build the iCalendar body (RFC 5545) describing a parking allocation. `cancel`
  # emits a METHOD:CANCEL that removes the previously-sent invite.
  protected def parking_invite_ics(booking : Booking, space_label : String?, cancel : Bool) : String
    method = cancel ? ICS_METHOD_CANCEL : ICS_METHOD_REQUEST
    stamp = Time.utc.to_s("%Y%m%dT%H%M%SZ")
    dtstart = Time.unix(booking.booking_start).to_s("%Y%m%dT%H%M%SZ")
    dtend = Time.unix(booking.booking_end).to_s("%Y%m%dT%H%M%SZ")

    # SEQUENCE must never regress across a booking's lifecycle: a CANCEL has to
    # outrank the REQUEST it supersedes or clients ignore it. last_changed
    # advances on every booking edit; the +1 on cancel guarantees the
    # cancellation wins even when built from the same booking snapshot.
    sequence = booking.last_changed || 0_i64
    sequence += 1 if cancel

    building = building_zone.display_name.presence || building_zone.name
    label = space_label.presence || "Parking"
    summary = "Parking - #{label}"
    location = "#{label}, #{building}"
    description = "Your parking space (#{label}) at #{building}."
    status = cancel ? "CANCELLED" : "CONFIRMED"

    String.build do |io|
      io << "BEGIN:VCALENDAR\r\n"
      io << "VERSION:2.0\r\n"
      io << "PRODID:-//PlaceOS//Parking Approvals//EN\r\n"
      io << "CALSCALE:GREGORIAN\r\n"
      io << "METHOD:" << method << "\r\n"
      io << "BEGIN:VEVENT\r\n"
      io << "UID:" << invite_uid(booking) << "\r\n"
      io << "SEQUENCE:" << sequence << "\r\n"
      io << "DTSTAMP:" << stamp << "\r\n"
      io << "DTSTART:" << dtstart << "\r\n"
      io << "DTEND:" << dtend << "\r\n"
      io << "SUMMARY:" << ics_escape(summary) << "\r\n"
      io << "LOCATION:" << ics_escape(location) << "\r\n"
      io << "DESCRIPTION:" << ics_escape(description) << "\r\n"
      io << "ORGANIZER;CN=" << ics_escape(@calendar_invite_from_name) << ":mailto:" << @calendar_invite_from << "\r\n"
      io << "ATTENDEE;CN=" << ics_escape(booking.user_name) << ";PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:" << booking.user_email << "\r\n"
      io << "STATUS:" << status << "\r\n"
      # parking shouldn't mark the user busy on their calendar
      io << "TRANSP:TRANSPARENT\r\n"
      io << "END:VEVENT\r\n"
      io << "END:VCALENDAR\r\n"
    end
  end

  # Stable per-booking-instance UID so the approval REQUEST and any later CANCEL
  # refer to the same calendar entry. Recurring instances get distinct UIDs.
  protected def invite_uid(booking : Booking) : String
    base = booking.instance ? "parking-#{booking.id}-#{booking.instance}" : "parking-#{booking.id}"
    "#{base}@place.technology"
  end

  # Escape a text value for an iCalendar property (RFC 5545 §3.3.11). Backslash
  # is escaped first so we don't double-escape the escapes we introduce.
  protected def ics_escape(value : String) : String
    value.gsub('\\', "\\\\").gsub('\n', "\\n").gsub(',', "\\,").gsub(';', "\\;")
  end

  # ===================================
  # Emails
  # ===================================

  # The approval email is the one we must guarantee is delivered, so its "sent"
  # marker (access_granted_emailed) is distinct from the "access granted" state.
  # The send is blocking (.get_json) so a failure raises and we DON'T advance
  # the state — the next pass retries via handle_allocated_booking.
  protected def approved_email(booking : Booking, space : ParkingSpace) : Nil
    return if booking.process_state == "access_granted_emailed"

    # per-parking-area trigger so each area can have its own approval email
    group_id = approval_group_id(space)
    template = group_id ? "approved_#{group_id}" : "approved"

    mailer.send_template(
      booking.user_email,
      {"parking_request", template},
      common_template_args(booking, space),
      attachments: calendar_attachment(booking, space.identifier.presence || space.id, cancel: false),
    ).get_json

    update_state(booking, "access_granted_emailed")
  rescue error
    logger.warn(exception: error) { "failed to send approved email for booking #{booking.id}" }
  end

  # an allocated booking (access_granted/_emailed) is past the waiting stage
  WAITING_SENT = {"waiting_approval", "access_granted", "access_granted_emailed"}

  protected def waiting_approval_email(booking : Booking) : Nil
    return if WAITING_SENT.includes?(booking.process_state)

    # blocking send: only advance the state once the email actually went out
    mailer.send_template(
      booking.user_email,
      {"parking_request", "approval_required"},
      common_template_args(booking),
    ).get_json

    update_state(booking, "waiting_approval")
  rescue error
    logger.warn(exception: error) { "failed to send waiting approval email for booking #{booking.id}" }
  end

  # an allocated booking (access_granted/_emailed) is past the wait-list stage
  WAIT_LIST_SENT = {"wait_list", "access_granted", "access_granted_emailed"}

  protected def wait_list_email(booking : Booking) : Nil
    return if WAIT_LIST_SENT.includes?(booking.process_state)

    # blocking send: only advance the state once the email actually went out
    mailer.send_template(
      booking.user_email,
      {"parking_request", "wait_list"},
      common_template_args(booking),
    ).get_json

    update_state(booking, "wait_list")
  rescue error
    logger.warn(exception: error) { "failed to send wait list email for booking #{booking.id}" }
  end

  protected def displaced_email(booking : Booking, reason : String) : Nil
    # the space the booking last held (set on allocate) — used to label the
    # cancellation; nil just yields a generic cancel that still removes the entry
    label = booking.extension_data["location"]?.try(&.as_s?)
    mailer.send_template(
      booking.user_email,
      {"parking_request", "displaced"},
      common_template_args(booking).merge({reason: reason}),
      attachments: calendar_attachment(booking, label, cancel: true),
    ).get_json
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
