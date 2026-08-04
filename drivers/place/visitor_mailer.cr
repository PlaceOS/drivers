require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "placeos-models/placeos-models/base/jwt"

require "./password_generator_helper"
require "./visitor_models"

require "uuid"
require "oauth2"
require "jwt"

class Place::VisitorMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Visitor Mailer"
  generic_name :VisitorMailer
  description %(emails visitors when they are invited and notifies hosts when they check in)

  default_settings({
    timezone:                  "GMT",
    date_time_format:          "%c",
    time_format:               "%l:%M%p",
    date_format:               "%A, %-d %B",
    booking_space_name:        "Client Floor",
    determine_host_name_using: "calendar-driver",

    send_reminders:    "0 7 * * *",
    reminder_template: "visitor",
    event_template:    "event",
    # also used when a new visitor is added to an existing booking
    booking_template:                   "booking",
    notify_checkin_template:            "notify_checkin",
    notify_induction_accepted_template: "induction_accepted",
    notify_induction_declined_template: "induction_declined",
    notify_original_host_template:      "notify_original_host",
    # sent to the existing visitors when details change (date, time, location,
    # etc.): bookings (desk/resource) use booking_changed, calendar events
    # (rooms) use event_changed. Visitors added by the same edit are left out —
    # their invitation already carries the new details.
    booking_changed_template: "booking_changed",
    event_changed_template:   "event_changed",
    group_event_template:     "group_event",

    # Combine duplicate change emails sent within this many seconds; 0 disables.
    event_change_debounce: 15,
    # As above for bookings. This also buys the window needed to notice that a
    # visitor was added by the same edit, so 0 will re-notify new visitors.
    booking_change_debounce:            15,
    disable_qr_code:                    false,
    send_network_credentials:           false,
    network_password_length:            DEFAULT_PASSWORD_LENGTH,
    network_password_exclude:           DEFAULT_PASSWORD_EXCLUDE,
    network_password_minimum_lowercase: DEFAULT_PASSWORD_MINIMUM_LOWERCASE,
    network_password_minimum_uppercase: DEFAULT_PASSWORD_MINIMUM_UPPERCASE,
    network_password_minimum_numbers:   DEFAULT_PASSWORD_MINIMUM_NUMBERS,
    network_password_minimum_symbols:   DEFAULT_PASSWORD_MINIMUM_SYMBOLS,
    network_group_ids:                  [] of String,
    debug:                              false,
    zone_cache_timeout:                 300,
    host_domain_filter:                 [] of String,

    disable_event_visitors: true,
    invite_zone_tag:        "building",
    is_campus:              false,

    # Suppresses the `booking` template when the booking has an
    # extension_data.parent_id (i.e. auto-created from a calendar event that
    # already triggers the `event` template).
    skip_event_linked_booking_email: true,

    # When true, the host will not receive any visitor-targeted emails
    # (invites, check-in notifications, booking-changed notifications, etc.)
    # even if they appear in the attendee / guest list.  Templates that
    # explicitly target the host (e.g. `notify_original_host_template`) are
    # unaffected.
    skip_host_email: true,

    # When true, attendees whose email domain matches the host's are treated as
    # colleagues rather than visitors and are not emailed. Front ends tend to
    # mark every attendee as an expected visitor, so staff invited to a meeting
    # would otherwise receive visitor invites and QR codes.
    skip_internal_domain_email: false,

    domain_uri:      "https://example.com/",
    jwt_private_key: PlaceOS::Model::JWTBase.private_key,
  })

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1
  accessor network_provider : NetworkAccess_1 # Written for Cisco ISE Driver, but ideally compatible with others

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    # Guest has been marked as attending a meeting in person
    monitor("staff/guest/attending") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    # Booking induction status has been updated
    monitor("staff/guest/induction_accepted") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }
    monitor("staff/guest/induction_declined") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    # Booking host has been reassigned — notify the previous host
    monitor("staff/booking/host_changed") { |_subscription, payload| booking_host_changed_event(payload.gsub(/[^[:print:]]/, "")) }

    # Booking details have changed — notify all visitors if relevant fields changed
    monitor("staff/booking/changed") { |_subscription, payload| booking_changed_event(payload.gsub(/[^[:print:]]/, "")) }

    # Calendar event details have changed — notify visitors / previous host
    monitor("staff/event/changed") { |_subscription, payload| event_changed_event(payload.gsub(/[^[:print:]]/, "")) }

    on_update
  end

  @time_zone : Time::Location = Time::Location.load("GMT")

  @debug : Bool = false
  @is_parent_zone : Bool = false
  @users_checked_in : UInt64 = 0_u64
  @users_accepted_induction : UInt64 = 0_u64
  @users_declined_induction : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  @visitor_emails_sent : UInt64 = 0_u64
  @visitor_email_errors : UInt64 = 0_u64
  @disable_qr_code : Bool = false
  @host_domain_filter : Array(String) = [] of String

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  getter building_zone : ZoneDetails do
    find_building(control_system_zone_list)
  end

  getter parent_zone_ids : Array(String) = [] of String
  @booking_space_name : String = "Client Floor"
  @invite_zone_tag : String = "building"

  @zone_cache : ZoneCache = ZoneCache.new
  @zone_cache_timeout : Int64 = 300

  @reminder_template : String = "visitor"
  @send_reminders : String? = nil
  @event_template : String = "event"
  @booking_template : String = "booking"
  @notify_checkin_template : String = "notify_checkin"
  @notify_induction_accepted_template : String = "induction_accepted"
  @notify_induction_declined_template : String = "induction_declined"
  @notify_original_host_template : String = "notify_original_host"
  @booking_changed_template : String = "booking_changed"
  @event_changed_template : String = "event_changed"
  @group_event_template : String = "group_event"
  @determine_host_name_using : String = "calendar-driver"
  @send_network_credentials = false
  @network_password_length : Int32 = DEFAULT_PASSWORD_LENGTH
  @network_password_exclude : String = DEFAULT_PASSWORD_EXCLUDE
  @network_password_minimum_lowercase : Int32 = DEFAULT_PASSWORD_MINIMUM_LOWERCASE
  @network_password_minimum_uppercase : Int32 = DEFAULT_PASSWORD_MINIMUM_UPPERCASE
  @network_password_minimum_numbers : Int32 = DEFAULT_PASSWORD_MINIMUM_NUMBERS
  @network_password_minimum_symbols : Int32 = DEFAULT_PASSWORD_MINIMUM_SYMBOLS
  @network_group_ids = [] of String
  @disable_event_visitors : Bool = true
  @skip_event_linked_booking_email : Bool = true
  @skip_host_email : Bool = true
  @skip_internal_domain_email : Bool = false

  # Coalescing buffer for staff/{event,booking}/changed, swept once the window
  # elapses. seconds to buffer a change; 0 emails on every signal
  @event_change_debounce : Int32 = 15
  @booking_change_debounce : Int32 = 15
  #                  buffer_key => coalesced change awaiting its flush
  @pending_changes : Hash(String, PendingChange) = {} of String => PendingChange
  @pending_changes_lock : Mutex = Mutex.new

  # Visitors invited within the debounce window, so a change notification for
  # the same visit can leave them out: the invitation they are receiving already
  # carries the new details, and they never saw the old ones.
  #                  invite_key => expires (monotonic)
  @recent_invites : Hash(String, Time::Span) = {} of String => Time::Span
  @recent_invites_lock : Mutex = Mutex.new

  @uri : URI = URI.new
  @jwt_private_key : String = PlaceOS::Model::JWTBase.private_key

  def on_update
    @debug = setting?(Bool, :debug) || false
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @send_reminders = setting?(String, :send_reminders).presence
    @reminder_template = setting?(String, :reminder_template) || "visitor"
    @event_template = setting?(String, :event_template) || "event"
    @booking_template = setting?(String, :booking_template) || "booking"
    @notify_checkin_template = setting?(String, :notify_checkin_template) || "notify_checkin"
    @notify_induction_accepted_template = setting?(String, :notify_induction_accepted_template) || "induction_accepted"
    @notify_induction_declined_template = setting?(String, :notify_induction_declined_template) || "induction_declined"
    @notify_original_host_template = setting?(String, :notify_original_host_template) || "notify_original_host"
    @booking_changed_template = setting?(String, :booking_changed_template) || "booking_changed"
    @event_changed_template = setting?(String, :event_changed_template) || "event_changed"
    @group_event_template = setting?(String, :group_event_template) || "group_event"
    @event_change_debounce = setting?(Int32, :event_change_debounce) || 15
    @booking_change_debounce = setting?(Int32, :booking_change_debounce) || 15
    @disable_qr_code = setting?(Bool, :disable_qr_code) || false
    @determine_host_name_using = setting?(String, :determine_host_name_using) || "calendar-driver"
    @send_network_credentials = setting?(Bool, :send_network_credentials) || false
    @network_password_length = setting?(Int32, :password_length) || DEFAULT_PASSWORD_LENGTH
    @network_password_exclude = setting?(String, :password_exclude) || DEFAULT_PASSWORD_EXCLUDE
    @network_password_minimum_lowercase = setting?(Int32, :password_minimum_lowercase) || DEFAULT_PASSWORD_MINIMUM_LOWERCASE
    @network_password_minimum_uppercase = setting?(Int32, :password_minimum_uppercase) || DEFAULT_PASSWORD_MINIMUM_UPPERCASE
    @network_password_minimum_numbers = setting?(Int32, :password_minimum_numbers) || DEFAULT_PASSWORD_MINIMUM_NUMBERS
    @network_password_minimum_symbols = setting?(Int32, :password_minimum_symbols) || DEFAULT_PASSWORD_MINIMUM_SYMBOLS
    @network_group_ids = setting?(Array(String), :network_group_ids) || [] of String
    @host_domain_filter = setting?(Array(String), :host_domain_filter) || [] of String
    @disable_event_visitors = setting?(Bool, :disable_event_visitors) || false
    skip_event_linked = setting?(Bool, :skip_event_linked_booking_email)
    @skip_event_linked_booking_email = skip_event_linked.nil? ? true : skip_event_linked
    skip_host_email = setting?(Bool, :skip_host_email)
    @skip_host_email = skip_host_email.nil? ? true : skip_host_email
    @skip_internal_domain_email = setting?(Bool, :skip_internal_domain_email) || false
    @invite_zone_tag = setting?(String, :invite_zone_tag) || "building"
    @is_parent_zone = setting?(Bool, :is_campus) || false

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @booking_space_name = setting?(String, :booking_space_name).presence || "Client Floor"

    @uri = URI.parse(setting?(String, :domain_uri) || "")
    @jwt_private_key = setting?(String, :jwt_private_key) || PlaceOS::Model::JWTBase.private_key
    @zone_cache_timeout = setting?(Int64, :zone_cache_timeout) || 300_i64
    @zone_cache = ZoneCache.new

    zones = control_system_zone_list

    # Each buffered change carries the debounce it was accepted under, so a
    # sweep still drains entries left over from the previous settings.
    debounces = [@event_change_debounce, @booking_change_debounce].select(&.positive?)

    schedule.clear
    if reminders = @send_reminders
      schedule.cron(reminders, @time_zone) { send_reminder_emails }
    end

    if interval = debounces.min?
      # Sweeps at most every 5s, so a change waits its debounce plus up to one interval.
      schedule.every(interval.clamp(1, 5).seconds) { sweep_pending_changes }
    else
      # Nothing would sweep the buffer with every debounce switched off.
      flush_pending_changes("debounce disabled")
    end

    spawn { ensure_building_zone(zones) }
  end

  # The scheduler is dead by now, so nothing else would sweep the buffer.
  # Bounded to return within the driver manager's 6s unload budget.
  def on_unload
    flush_pending_changes("driver unloading", wait: 5.seconds)
  end

  def control_system_zone_list
    config.control_system.not_nil!.zones # ameba:disable Lint/NotNil
  end

  protected def ensure_building_zone(zones) : Nil
    find_building(zones)
  rescue error
    logger.warn(exception: error) { "error looking up building zone" }
    schedule.in(5.seconds) { ensure_building_zone(zones) }
  end

  protected def find_building(zones : Array(String)) : ZoneDetails
    zones.each do |zone_id|
      zone = fetch_zone(zone_id)
      if zone.tags.includes?(@invite_zone_tag)
        @building_zone = zone
        if @is_parent_zone && (child_zones = Array(ZoneDetails).from_json(staff_api.zones(parent: zone_id).get_json))
          @parent_zone_ids = child_zones.map(&.id)
        else
          @parent_zone_ids = [] of String
        end
        break
      end
    end
    raise "no building zone found in System" unless @building_zone
    @building_zone.as(ZoneDetails)
  end

  # Fetch a zone from the cache, or from the API if not cached / expired.
  # Follows the same pattern as TemplateMailer's template cache.
  protected def fetch_zone(zone_id : String) : ZoneDetails
    if (cached = @zone_cache[zone_id]?) && cached[0] > Time.utc.to_unix
      cached[1]
    else
      zone = ZoneDetails.from_json staff_api.zone(zone_id).get_json
      @zone_cache[zone_id] = {Time.utc.to_unix + @zone_cache_timeout, zone}
      zone
    end
  end

  def clear_zone_cache(zone_id : String? = nil)
    if zone_id && !zone_id.blank?
      @zone_cache.delete(zone_id)
    else
      @zone_cache = ZoneCache.new
    end
  end

  protected def guest_event(payload)
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = GuestNotification.from_json payload

    # ensure the event is for this building
    if zones = guest_details.zones
      check = [building_zone.id] + @parent_zone_ids

      if (check & zones).empty?
        logger.debug { "ignoring event as does not match any zones: #{check}" }
        return
      end
    end

    # An invitation is our only notice that a visitor has just been added to a
    # visit: staff-api signals attendance solely for attendees that weren't
    # already attending. Recorded ahead of the filters below so a visitor whose
    # invite email is suppressed (disable_event_visitors,
    # skip_event_linked_booking_email) still counts as newly invited — they were
    # invited, just via the other template.
    record_invite(guest_details) if guest_details.is_a?(EventGuest) || guest_details.is_a?(BookingGuest)

    # don't email staff members
    if !@host_domain_filter.empty? && guest_details.attendee_email.split('@', 2)[1].downcase.in?(@host_domain_filter)
      logger.debug { "ignoring event matches host domain filter" }
      return
    end

    # don't send a visitor-targeted email to the host.
    if @skip_host_email && (host_email = guest_details.host.presence) && guest_details.attendee_email.downcase == host_email.downcase
      logger.debug { "ignoring guest event as attendee #{guest_details.attendee_email} is the host" }
      return
    end

    # don't treat the host's colleagues as visitors
    if @skip_internal_domain_email && colleague_of_host?(guest_details.attendee_email, guest_details.host)
      logger.debug { "ignoring guest event as attendee #{guest_details.attendee_email} shares the host's domain" }
      return
    end

    case guest_details
    in GuestCheckin
      # the same signal is fired for check-out (state=false), only notify the
      # host of arrivals. checkin is nilable for backwards compatibility.
      if guest_details.checkin == false
        logger.debug { "ignoring guest checkin event as the visitor was checked out" }
        return
      end

      send_checkedin_email(
        @notify_checkin_template,
        guest_details.attendee_email,
        guest_details.attendee_name,
        guest_details.host,
        guest_details.event_title || guest_details.event_summary,
        guest_details.event_starting
      )
      self[:users_checked_in] = @users_checked_in += 1
      return
    in BookingInduction
      if guest_details.induction.accepted?
        send_induction_email(
          @notify_induction_accepted_template,
          guest_details.attendee_email,
          guest_details.attendee_name,
          guest_details.host,
          guest_details.event_title || guest_details.event_summary,
          guest_details.event_starting,
          guest_details.induction
        )
        self[:users_accepted_induction] = @users_accepted_induction += 1
      elsif guest_details.induction.declined?
        send_induction_email(
          @notify_induction_declined_template,
          guest_details.attendee_email,
          guest_details.attendee_name,
          guest_details.host,
          guest_details.event_title || guest_details.event_summary,
          guest_details.event_starting,
          guest_details.induction
        )
        self[:users_declined_induction] = @users_declined_induction += 1
      end

      return
    in EventGuest
      return if @disable_event_visitors

      room = get_room_details(guest_details.system_id)
      area_name = room.display_name.presence || room.name
      template = @event_template
    in BookingGuest
      area_name = @booking_space_name
      template = @booking_template
      booking = staff_api.get_booking(guest_details.booking_id).get

      if @skip_event_linked_booking_email
        parent_id = booking.dig?("extension_data", "parent_id").try(&.as_s?)
        if parent_id && !parent_id.empty?
          logger.debug { "skipping booking_created email for booking #{guest_details.booking_id} as it is linked to event #{parent_id}" }
          return
        end
      end

      booking_type = booking["booking_type"].as_s
      template = @group_event_template if booking_type == "group-event"
    in GuestNotification
      # should never get here
      return
    end

    logger.debug { "emailing the #{template} invite to #{guest_details.attendee_email}" }

    begin
      send_visitor_qr_email(
        template,
        guest_details.attendee_email,
        guest_details.attendee_name,
        guest_details.host,
        guest_details.event_title || guest_details.event_summary,
        guest_details.event_starting,
        guest_details.resource_id,
        guest_details.event_id,
        area_name,
        system_id: guest_details.responds_to?(:system_id) ? guest_details.system_id : nil,
      )
    rescue error
      # counted separately from error_count so a missing invite can be told
      # apart from a failure anywhere else in this handler
      self[:visitor_email_errors] = @visitor_email_errors += 1
      raise error
    end

    self[:visitor_emails_sent] = @visitor_emails_sent += 1
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:error_count] = @error_count += 1
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  payload,
    }
  end

  @[Security(Level::Support)]
  def send_checkedin_email(
    template : String,
    visitor_email : String,
    visitor_name : String?,
    host_email : String?,
    event_title : String?,
    event_start : Int64,
  )
    local_start_time = Time.unix(event_start).in(@time_zone)

    mailer.send_template(
      host_email,
      {"visitor_invited", template}, # Template selection: "visitor_invited" "notify_checkin"
      {
      visitor_email: visitor_email,
      visitor_name:  visitor_name,
      host_name:     get_host_name(host_email),
      host_email:    host_email,
      building_name: building_zone.display_name.presence || building_zone.name,
      event_title:   event_title,
      event_start:   local_start_time.to_s(@time_format),
      event_date:    local_start_time.to_s(@date_format),
      event_time:    local_start_time.to_s(@time_format),
    },
      reply_to: host_email.presence,
    )
  end

  @[Security(Level::Support)]
  def send_induction_email(
    template : String,
    visitor_email : String,
    visitor_name : String?,
    host_email : String?,
    event_title : String?,
    event_start : Int64,
    induction_status : Induction,
  )
    local_start_time = Time.unix(event_start).in(@time_zone)

    mailer.send_template(
      host_email,
      {"visitor_invited", template}, # Template selection: "visitor_invited" "induction_accepted"
      {
      visitor_email:    visitor_email,
      visitor_name:     visitor_name,
      host_name:        get_host_name(host_email),
      host_email:       host_email,
      building_name:    building_zone.display_name.presence || building_zone.name,
      event_title:      event_title,
      event_start:      local_start_time.to_s(@time_format),
      event_date:       local_start_time.to_s(@date_format),
      event_time:       local_start_time.to_s(@time_format),
      induction_status: induction_status.to_s,
    },
      reply_to: host_email.presence,
    )
  end

  protected def booking_host_changed_event(payload)
    logger.debug { "received booking host changed payload: #{payload}" }
    details = BookingHostChanged.from_json payload

    # ensure the event is for this building
    if zones = details.zones
      check = [building_zone.id] + @parent_zone_ids

      if (check & zones).empty?
        logger.debug { "ignoring host_changed event as does not match any zones: #{check}" }
        return
      end
    end

    send_original_host_email(
      @notify_original_host_template,
      details.previous_host_email,
      details.new_host_email,
      details.event_title || details.event_summary,
      details.event_starting,
    )
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:error_count] = @error_count += 1
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  payload,
    }
  end

  @[Security(Level::Support)]
  def send_original_host_email(
    template : String,
    previous_host_email : String,
    new_host_email : String,
    event_title : String?,
    event_start : Int64?,
  )
    # A host can be reassigned via a metadata-only update that carries no event
    # timing, so render the date/time only when a start time is available.
    local_start_time = event_start.try { |timestamp| Time.unix(timestamp).in(@time_zone) }

    mailer.send_template(
      previous_host_email,
      {"visitor_invited", template},
      {
        previous_host_email: previous_host_email,
        previous_host_name:  get_host_name(previous_host_email),
        new_host_email:      new_host_email,
        new_host_name:       get_host_name(new_host_email),
        building_name:       building_zone.display_name.presence || building_zone.name,
        event_title:         event_title,
        event_date:          local_start_time.try(&.to_s(@date_format)),
        event_time:          local_start_time.try(&.to_s(@time_format)),
      },
      reply_to: new_host_email.presence,
    )
  end

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(@time_zone)
    common_fields = [
      {name: "visitor_email", description: "Email address of the visiting guest"},
      {name: "visitor_name", description: "Full name of the visiting guest"},
      {name: "host_name", description: "Name of the person hosting the visitor"},
      {name: "host_email", description: "Email address of the host"},
      {name: "building_name", description: "Name of the building where the visit occurs"},
      {name: "event_title", description: "Title or purpose of the visit"},
      {name: "event_start", description: "Start time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "event_date", description: "Date of the visit (e.g., #{time_now.to_s(@date_format)})"},
      {name: "event_time", description: "Time of the visit (or 'all day' for 24-hour events)"},
    ]

    invitation_fields = common_fields + [
      {name: "room_name", description: "Name of the room or area being visited"},
      {name: "network_username", description: "Network access username (if network credentials enabled)"},
      {name: "network_password", description: "Generated network access password (if network credentials enabled)"},
    ]

    induction_fields = common_fields + [
      {name: "induction_status", description: "Status of the induction (e.g., accepted or declined)"},
    ]

    jwt_fields = [
      {name: "guest_jwt", description: "JWT token for the guest"},
      {name: "kiosk_url", description: "URL for the visitor kiosk"},
    ]

    # Shared by the booking-changed and event-changed notifications, which carry
    # the same data but render through separate templates.
    changed_fields = common_fields + [
      {name: "room_name", description: "Name of the room or area being visited"},
      {name: "previous_event_date", description: "The original date before it was changed"},
      {name: "previous_event_time", description: "The original time before it was changed"},
      {name: "previous_room_name", description: "The original room or area name before it was moved"},
      {name: "previous_building_name", description: "The original building name before it was moved"},
    ] + jwt_fields

    [
      TemplateFields.new(
        trigger: {"visitor_invited", @reminder_template},
        name: "Visitor invited",
        description: "Reminder email for upcoming visitor appointments",
        fields: invitation_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @event_template},
        name: "Visitor invited to event",
        description: "Initial invitation for a visitor attending a calendar event",
        fields: invitation_fields + jwt_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @booking_template},
        name: "Visitor invited to booking",
        description: "Invitation for a visitor with a booking. Sent on initial booking creation and also when a new visitor is added to an existing booking",
        fields: invitation_fields + jwt_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @group_event_template},
        name: "Visitor invited to group event booking",
        description: "Initial invitation for a visitor attending a group event",
        fields: invitation_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @notify_checkin_template},
        name: "Visitor check in notification",
        description: "Notification to host when their visitor checks in",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @notify_induction_accepted_template},
        name: "Visitor induction accepted notification",
        description: "Notification to host when their visitor accepts the induction",
        fields: induction_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @notify_induction_declined_template},
        name: "Visitor induction declined notification",
        description: "Notification to host when their visitor declines the induction",
        fields: induction_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @notify_original_host_template},
        name: "Original host reassigned notification",
        description: "Notification to the original host when a booking's host is changed to someone else",
        fields: [
          {name: "previous_host_email", description: "Email address of the original host being replaced"},
          {name: "previous_host_name", description: "Name of the original host being replaced"},
          {name: "new_host_email", description: "Email address of the new host taking over the booking"},
          {name: "new_host_name", description: "Name of the new host taking over the booking"},
          {name: "building_name", description: "Name of the building where the booking occurs"},
          {name: "event_title", description: "Title or purpose of the booking"},
          {name: "event_date", description: "Date of the booking"},
          {name: "event_time", description: "Time of the booking"},
        ]
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @booking_changed_template},
        name: "Booking details changed notification",
        description: "Notification sent to the existing visitors on a booking (desk/resource) when details change (date, time, etc.). Visitors added by the same edit are sent their invitation instead",
        fields: changed_fields
      ),
      TemplateFields.new(
        trigger: {"visitor_invited", @event_changed_template},
        name: "Event details changed notification",
        description: "Notification sent to the existing visitors on a calendar event (room) when details change (date, time, location, etc.). Visitors added by the same edit are sent their invitation instead",
        fields: changed_fields
      ),
    ]
  end

  protected def booking_changed_event(payload)
    logger.debug { "received booking changed payload: #{payload}" }
    details = BookingChanged.from_json payload

    # Only process actions that can carry visitor-relevant changes.
    # Using an allowlist ensures new action types (e.g. "approved", "rejected",
    # "checked_in") are ignored by default and don't trigger spurious emails.
    return unless details.action.in?("changed", "metadata_changed")

    # NOTE: event-linked bookings (extension_data.parent_id set — e.g. the
    # visitor bookings attendee_scanner creates for external calendar guests)
    # are intentionally NOT skipped here. Editing a booking only emits
    # staff/booking/changed; the linked calendar event is left untouched, so no
    # staff/event/changed fires to cover it. Skipping them dropped the visitor's
    # only change notification (PPT-2375). Duplicate suppression for the initial
    # invite still lives in guest_event, where a genuine event+booking
    # double-invite occurs on creation.

    # ensure the event is for this building
    if zones = details.zones
      check = [building_zone.id] + @parent_zone_ids

      if (check & zones).empty?
        logger.debug { "ignoring booking_changed event as does not match any zones: #{check}" }
        return
      end
    end

    # Check if any booking field that warrants a visitor notification has changed.
    # Add new field comparisons here as more change notifications are introduced.
    fields_changed = false

    # Date or time changed
    if prev_start = details.previous_booking_start
      fields_changed = true if prev_start != details.booking_start
    end
    if prev_end = details.previous_booking_end
      fields_changed = true if prev_end != details.booking_end
    end

    # Location changed: zones identify the building/room the visitor should attend
    if prev_zones = details.previous_zones
      fields_changed = true if prev_zones.sort != (details.zones || [] of String).sort
    end

    return unless fields_changed

    # Buffer rather than send now: a group visitor edit updates the parent
    # booking before adding this edit's new visitors in later requests, so the
    # debounce is what lets us recognise those visitors and leave them out.
    change = PendingBookingChange.new(
      @booking_change_debounce,
      details.id, details.booking_type, details.user_email, details.title,
      details.resource_id, details.booking_start, details.booking_end,
      details.previous_booking_start, details.previous_booking_end,
      details.zones, details.previous_zones,
    )
    @booking_change_debounce > 0 ? buffer_change(change) : dispatch_booking_change(change)
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:error_count] = @error_count += 1
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  payload,
    }
  end

  protected def event_changed_event(payload)
    logger.debug { "received event changed payload: #{payload}" }
    details = EventChanged.from_json payload

    # only respond to updates, not creates or cancellations
    return unless details.action == "update"

    # ensure the event is for this building
    if zones = details.zones
      check = [building_zone.id] + @parent_zone_ids

      if (check & zones).empty?
        logger.debug { "ignoring event_changed as does not match any zones: #{check}" }
        return
      end
    end

    # The (new) host is required for every notification below.
    host = details.host
    return unless host

    # event_start may be omitted from metadata-only update signals (e.g. an
    # update_metadata that only touched ext_data). Look it up so the host
    # notification and change emails always render a real date.
    event_start = details.event_start || lookup_event_start(details.event_id, details.system_id)

    # --- Host change notification
    # A host can be reassigned without any change to the event timing; the host
    # email still renders (date/time blank only if the lookup also came up empty).
    if (prev_host = details.previous_host_email) && prev_host.downcase != host.downcase
      send_original_host_email(
        @notify_original_host_template,
        prev_host,
        host,
        details.title,
        event_start,
      )
    end

    # --- Date / time / location change notification
    # These genuinely require the event timing to render the new schedule, so
    # bail out when it is missing.
    event_end = details.event_end
    return unless event_start && event_end

    fields_changed = false

    # Date or time changed
    if prev_start = details.previous_event_start
      fields_changed = true if prev_start != event_start
    end
    if prev_end = details.previous_event_end
      fields_changed = true if prev_end != event_end
    end

    # Location changed (system_id represents the room)
    if prev_sys = details.previous_system_id
      fields_changed = true if prev_sys != details.system_id
    end

    return unless fields_changed

    # Coalesce the burst of signals Office365 emits per edit into one email.
    change = PendingEventChange.new(
      @event_change_debounce,
      details.event_id, details.system_id, details.event_ical_uid,
      host, details.title, event_start, event_end,
      details.previous_event_start, details.previous_event_end, details.previous_system_id,
    )
    @event_change_debounce > 0 ? buffer_change(change) : dispatch_event_change(change)
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:error_count] = @error_count += 1
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  payload,
    }
  end

  # Whether the attendee is a colleague of the host rather than a visitor.
  protected def colleague_of_host?(attendee_email : String, host_email : String?) : Bool
    return false if host_email.nil? || host_email.blank?
    attendee_domain = attendee_email.split('@', 2)[1]?
    host_domain = host_email.split('@', 2)[1]?
    return false unless attendee_domain && host_domain
    attendee_domain.downcase == host_domain.downcase
  end

  # Remembers that a visitor was just invited, so a change notification for the
  # same visit can leave them out. Expired entries are dropped on the way in,
  # which keeps the map to a couple of minutes' worth of invites even with every
  # debounce off (and so no sweep running to prune it).
  protected def record_invite(guest_details : GuestNotification) : Nil
    key = invite_key(guest_details.attendee_email, guest_details.host, guest_details.event_starting)
    now = Time.monotonic

    @recent_invites_lock.synchronize do
      @recent_invites.reject! { |_key, expires| expires <= now }
      @recent_invites[key] = now + invite_memory
    end

    logger.debug { "noted #{guest_details.attendee_email} as newly invited by #{guest_details.host}" }
  end

  # Whether this visitor was invited to this visit within the memory window.
  protected def recently_invited?(visitor_email : String, host_email : String, event_start : Int64) : Bool
    key = invite_key(visitor_email, host_email, event_start)
    now = Time.monotonic

    @recent_invites_lock.synchronize do
      if expires = @recent_invites[key]?
        next true if expires > now
        @recent_invites.delete(key)
      end
      false
    end
  end

  # A change notification names the parent booking while the invitation names the
  # visitor's own child booking, and for an event-linked visitor booking the ids
  # don't correspond at all. Both do always describe the same visitor attending
  # the same host's visit at the same (new) start time, so key on that instead.
  private def invite_key(visitor_email : String, host_email : String?, event_start : Int64) : String
    "#{visitor_email.strip.downcase}\t#{host_email.to_s.strip.downcase}\t#{event_start}"
  end

  # Long enough to cover the debounce holding a change notification back, plus
  # room for a front end that adds its visitors in requests which follow the one
  # that made the change.
  private def invite_memory : Time::Span
    {@event_change_debounce, @booking_change_debounce}.max.clamp(0, 3600).seconds + 60.seconds
  end

  # Collapses the burst of signals for one edit into a single buffered change.
  # Events are keyed by instance, so the rooms either side of a move coalesce
  # too; the one email then names a single room and uses that room's guest list.
  private def buffer_change(change : PendingChange) : Nil
    @pending_changes_lock.synchronize do
      if pending = @pending_changes[change.buffer_key]?
        pending.merge(change)
      else
        @pending_changes[change.buffer_key] = change
      end
    end
  end

  # Sends any change that has been buffered for its full debounce window.
  private def sweep_pending_changes : Nil
    flush_pending_changes("debounce window elapsed", ready_only: true)
  end

  # Dispatches buffered changes, each in its own fiber so a slow send can't stall
  # the sweep. `ready_only` limits the flush to entries that have served their
  # debounce, `wait` bounds how long we block for the sends to finish.
  private def flush_pending_changes(reason : String, ready_only : Bool = false, wait : Time::Span? = nil) : Nil
    flushing = @pending_changes_lock.synchronize do
      now = Time.monotonic
      ready = if ready_only
                @pending_changes.values.select(&.ready?(now))
              else
                @pending_changes.values
              end
      ready.each { |pending| @pending_changes.delete(pending.buffer_key) }
      ready
    end
    return if flushing.empty?

    logger.debug { "flushing #{flushing.size} pending change(s): #{reason}" }

    complete = Channel(Nil).new(flushing.size)
    flushing.each do |pending|
      spawn do
        case pending
        in PendingEventChange   then dispatch_event_change(pending)
        in PendingBookingChange then dispatch_booking_change(pending)
        in PendingChange        then logger.error { "no dispatcher for pending change #{pending.buffer_key}" }
        end
      rescue error
        logger.error { error.inspect_with_backtrace }
        self[:error_count] = @error_count += 1
        self[:last_error] = {
          error: error.message,
          time:  Time.local.to_s,
          user:  "flushing change #{pending.buffer_key}: #{reason}",
        }
      ensure
        complete.send(nil)
      end
    end
    return unless wait

    deadline = Time.monotonic + wait
    flushing.size.times do |index|
      remaining = deadline - Time.monotonic
      remaining = Time::Span.zero if remaining < Time::Span.zero

      select
      when complete.receive
      when timeout(remaining)
        logger.warn { "timeout flushing pending changes: #{reason}, #{flushing.size - index} of #{flushing.size} still in flight" }
        break
      end
    end
  end

  # Resolves locations, fetches guests and emails visitors about a booking
  # change. Shared by the immediate and debounced paths.
  private def dispatch_booking_change(change : PendingBookingChange)
    # Skip a coalesced no-op (e.g. an edit that was undone within the window).
    return unless change.changed?

    # Resolve previous location names from previous zones
    previous_building_name = building_zone.display_name.presence || building_zone.name
    previous_room_name = @booking_space_name

    if prev_zones = change.previous_zones
      found_building = false
      found_room = false
      prev_zones.each do |zone_id|
        break if found_building && found_room
        begin
          zone = fetch_zone(zone_id)
          if zone.tags.includes?(@invite_zone_tag)
            previous_building_name = zone.display_name.presence || zone.name
            found_building = true
          else
            previous_room_name = zone.display_name.presence || zone.name
            found_room = true
          end
        rescue error
          logger.warn(exception: error) { "error looking up previous zone #{zone_id}" }
        end
      end
    end

    # include_linked: true ensures guests from child bookings (e.g. per-visitor
    # bookings under a group parent) are returned in a single request.
    guests = staff_api.booking_guests(change.booking_id, include_linked: change.booking_type == "group").get.as_a

    send_booking_changed_emails(
      guests,
      @booking_changed_template,
      change.host,
      change.current_start,
      change.title,
      change.previous_start,
      previous_building_name,
      previous_room_name,
      event_id: change.booking_id.to_s,
      resource_id: change.resource_id,
    )
  end

  # Resolves locations, fetches guests and emails visitors about an event change.
  # Shared by the immediate and debounced paths.
  private def dispatch_event_change(change : PendingEventChange)
    system_id = change.system_id
    previous_system_id = change.previous_system_id

    # Skip a coalesced no-op (e.g. an A->B->A flip-flop that nets to no change).
    return unless change.changed?

    current_building_name = building_zone.display_name.presence || building_zone.name
    current_room_name = @booking_space_name
    current_room_name, current_building_name = resolve_system_location_names(system_id, current_room_name, current_building_name)

    # Default the previous location to the current one; only override it when the
    # room actually changed. This keeps date/time-only edits showing the same
    # (unchanged) room in both the "previous" and "new" sections instead of the
    # static @booking_space_name fallback.
    previous_building_name = current_building_name
    previous_room_name = current_room_name

    if change.moved_room? && (prev_sys_id = previous_system_id)
      # Use "unknown" as the room fallback so a failed lookup surfaces in the
      # email rather than silently showing the current room name.
      previous_room_name, previous_building_name = resolve_system_location_names(prev_sys_id, "unknown", current_building_name)
    end

    guests = staff_api.event_guests(change.event_id, system_id, change.event_ical_uid).get.as_a
    send_booking_changed_emails(
      guests,
      @event_changed_template,
      change.host,
      change.current_start,
      change.title,
      change.previous_start,
      previous_building_name,
      previous_room_name,
      current_building_name,
      current_room_name,
      event_id: change.event_id,
      resource_id: system_id,
      system_id: system_id,
    )
  end

  # `building_name` / `room_name` override the current location names; when
  # omitted they fall back to `building_zone` / `@booking_space_name` (used by
  # the booking flow, which has no system_id to resolve from).
  #
  # `event_id` / `resource_id` / `system_id` identify the visit for the QR code
  # and kiosk link; supplying them mirrors what the invitation email carries, so
  # a visitor whose meeting moved has a check-in code for the new room.
  private def send_booking_changed_emails(
    guests : Array(JSON::Any),
    template : String,
    host_email : String,
    event_start : Int64,
    event_title : String?,
    previous_start : Int64?,
    previous_building_name : String,
    previous_room_name : String,
    building_name : String? = nil,
    room_name : String? = nil,
    event_id : String? = nil,
    resource_id : String? = nil,
    system_id : String? = nil,
  )
    resolved_building_name = building_name || (building_zone.display_name.presence || building_zone.name)
    resolved_room_name = room_name || @booking_space_name

    guests.each do |guest|
      visitor_email = guest["email"].as_s
      visitor_name = guest["name"].as_s?

      # don't email the host their own booking_changed notification.
      next if @skip_host_email && visitor_email.downcase == host_email.downcase

      # don't email staff members
      next if !@host_domain_filter.empty? && visitor_email.split('@', 2)[1].downcase.in?(@host_domain_filter)

      # don't treat the host's colleagues as visitors
      next if @skip_internal_domain_email && colleague_of_host?(visitor_email, host_email)

      # don't tell a visitor added by this very edit that their visit changed —
      # the invitation they are receiving already carries these details, and
      # there is nothing they knew of to have changed (PPT-2375)
      if recently_invited?(visitor_email, host_email, event_start)
        logger.debug { "skipping #{template} email to #{visitor_email} as they were just invited" }
        next
      end

      local_start_time = Time.unix(event_start).in(@time_zone)

      previous_date = previous_start.try { |timestamp| Time.unix(timestamp).in(@time_zone).to_s(@date_format) }
      previous_time = previous_start.try { |timestamp| Time.unix(timestamp).in(@time_zone).to_s(@time_format) }

      guest_jwt = kiosk_url = ""
      attach = [] of NamedTuple(file_name: String, content: String, content_id: String)

      if event_id
        qr_resource = resource_id.presence || system_id.presence || ""
        jwt_resource = system_id.presence || resource_id.presence || ""

        guest_jwt = generate_guest_jwt(visitor_name || visitor_email, visitor_email, visitor_email, event_id, jwt_resource)
        kiosk_url = "/visitor-kiosk/?email=#{visitor_email}&token=#{guest_jwt}&event_id=#{event_id}#/checkin/preferences"

        unless @disable_qr_code
          qr_png = mailer.generate_png_qrcode(text: "VISIT:#{visitor_email},#{qr_resource},#{event_id},#{host_email}", size: 256).get.as_s
          attach = [
            {
              file_name:  "qr.png",
              content:    qr_png,
              content_id: visitor_email,
            },
          ]
        end
      end

      mailer.send_template(
        visitor_email,
        {"visitor_invited", template},
        {
          visitor_email:          visitor_email,
          visitor_name:           visitor_name,
          host_name:              get_host_name(host_email),
          host_email:             host_email,
          room_name:              resolved_room_name,
          building_name:          resolved_building_name,
          event_title:            event_title,
          event_start:            local_start_time.to_s(@time_format),
          event_date:             local_start_time.to_s(@date_format),
          event_time:             local_start_time.to_s(@time_format),
          previous_event_date:    previous_date,
          previous_event_time:    previous_time,
          previous_room_name:     previous_room_name,
          previous_building_name: previous_building_name,
          guest_jwt:              guest_jwt,
          kiosk_url:              kiosk_url,
        },
        attach,
        reply_to: host_email.presence,
      )
    rescue error
      logger.warn(exception: error) { "failed to send booking_changed email to #{visitor_email}" }
    end
  end

  # Returns `{room_name, building_name}` for `system_id`, falling back to the
  # supplied values (and logging a warning) if any lookup fails.
  private def resolve_system_location_names(system_id : String, fallback_room : String, fallback_building : String) : {String, String}
    room_name = fallback_room
    building_name = fallback_building

    begin
      sys = get_room_details(system_id)
      room_name = sys.display_name.presence || sys.name
      if zones = sys.zones
        zones.each do |zone_id|
          begin
            zone = fetch_zone(zone_id)
            if zone.tags.includes?(@invite_zone_tag)
              building_name = zone.display_name.presence || zone.name
              break
            end
          rescue error
            logger.warn(exception: error) { "error looking up zone #{zone_id} for system #{system_id}" }
          end
        end
      end
    rescue error
      logger.warn(exception: error) { "error looking up system #{system_id}" }
    end

    {room_name, building_name}
  end

  @[Security(Level::Support)]
  def send_visitor_qr_email(
    template : String,
    visitor_email : String,
    visitor_name : String?,
    host_email : String?,
    event_title : String?,
    event_start : Int64,

    resource_id : String,
    event_id : String,
    area_name : String,

    event_end : Int64? = nil,
    system_id : String? = nil,
  )
    local_start_time = Time.unix(event_start).in(@time_zone)

    attach = if @disable_qr_code
               [] of NamedTuple(file_name: String, content: String, content_id: String)
             else
               qr_png = mailer.generate_png_qrcode(text: "VISIT:#{visitor_email},#{resource_id},#{event_id},#{host_email}", size: 256).get.as_s
               [
                 {
                   file_name:  "qr.png",
                   content:    qr_png,
                   content_id: visitor_email,
                 },
               ]
             end

    network_username = network_password = ""
    network_username, network_password = update_network_user_password(
      visitor_email,
      generate_password(
        length: @network_password_length,
        exclude: @network_password_exclude,
        minimum_lowercase: @network_password_minimum_lowercase,
        minimum_uppercase: @network_password_minimum_uppercase,
        minimum_numbers: @network_password_minimum_numbers,
        minimum_symbols: @network_password_minimum_symbols
      ),
      @network_group_ids
    ) if @send_network_credentials

    event_time = if (end_timestamp = event_end) && (Time.unix(end_timestamp) - Time.unix(event_start)) == 24.hours
                   "all day"
                 else
                   local_start_time.to_s(@time_format)
                 end

    guest_jwt = generate_guest_jwt(visitor_name || visitor_email, visitor_email, visitor_email, event_id, system_id || resource_id)
    kiosk_url = "/visitor-kiosk/?email=#{visitor_email}&token=#{guest_jwt}&event_id=#{event_id}#/checkin/preferences"

    mailer.send_template(
      visitor_email,
      {"visitor_invited", template}, # Template selection: "visitor_invited" action, "visitor" email
      {
      visitor_email:    visitor_email,
      visitor_name:     visitor_name,
      host_name:        get_host_name(host_email),
      host_email:       host_email,
      room_name:        area_name,
      building_name:    building_zone.display_name.presence || building_zone.name,
      event_title:      event_title,
      event_start:      local_start_time.to_s(@time_format),
      event_date:       local_start_time.to_s(@date_format),
      event_time:       event_time,
      network_username: network_username,
      network_password: network_password,
      guest_jwt:        guest_jwt,
      kiosk_url:        kiosk_url,
    },
      attach,
      reply_to: host_email.presence,
    )
  end

  @[Security(Level::Support)]
  def send_reminder_emails
    now = 1.hour.ago.to_unix
    later = 12.hours.from_now.to_unix

    guests = staff_api.query_guests(
      period_start: now,
      period_end: later,
      zones: {building_zone.id}
    ).get.as_a

    guests.uniq! { |guest| guest["email"].as_s.downcase }
    guests.each do |guest|
      begin
        if event = guest["event"]?
          send_visitor_qr_email(
            @reminder_template,
            guest["email"].as_s,
            guest["name"].as_s?,
            event["host"].as_s,
            event["title"].as_s,
            event["event_start"].as_i64,
            event.dig("system", "id").as_s,
            event["id"].as_s,
            (event.dig?("system", "display_name") || event.dig("system", "name")).as_s,
            event_end: event["event_end"].as_i64
          )
        elsif booking = guest["booking"]?
          send_visitor_qr_email(
            @reminder_template,
            guest["email"].as_s,
            guest["name"].as_s?,
            booking["user_email"].as_s,
            booking["title"].as_s?,
            booking["booking_start"].as_i64,
            booking["asset_id"].as_s,
            booking["id"].as_i64.to_s,
            @booking_space_name,
            event_end: booking["booking_end"].as_i64
          )
        end
      rescue error
        logger.warn(exception: error) { "failed to send reminder email to #{guest["email"]}" }
      end
    end
  end

  # ===================================
  # Guest JWT Generation:
  # ===================================

  @[Security(Level::Administrator)]
  def generate_guest_jwt(name : String, email : String, guest_id : String, event_id : String, system_id : String)
    now = Time.local(@time_zone)
    tonight = now.at_end_of_day
    tomorrow_night = tonight + 24.hours

    payload = {
      iss:   "POS",
      iat:   now.to_unix,
      exp:   tomorrow_night.to_unix,
      jti:   UUID.random.to_s,
      aud:   @uri.try &.host,
      scope: ["guest", "metadata"],
      sub:   guest_id,
      u:     {
        n: name,
        e: email,
        p: 0,
        r: [event_id, system_id, building_zone.id],
      },
    }

    JWT.encode(payload, @jwt_private_key, JWT::Algorithm::RS256)
  end

  # ===================================
  # PlaceOS API requests
  # ===================================

  class ZoneDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property location : String?
    property tags : Array(String)
    property parent_id : String?
  end

  # A change buffered awaiting a debounced flush. `current_*` follow the latest
  # signal in the burst, `previous_*` and `first_seen` stay as they were when it
  # started, so the email describes the net change of the whole edit.
  #
  # Buffer keys are namespaced per subclass, so the two kinds of change can never
  # collide even when a booking id and an event id coincide.
  abstract class PendingChange
    property host : String
    property title : String?
    property current_start : Int64
    property current_end : Int64
    property previous_start : Int64?
    property previous_end : Int64?

    getter first_seen : Time::Span = Time.monotonic
    getter buffer_key : String = ""
    # The debounce this change was accepted under, kept per entry so a sweep
    # still drains anything left over from the previous settings.
    getter debounce : Time::Span = Time::Span.zero

    def initialize(debounce_seconds : Int32, @host, @title, @current_start, @current_end, @previous_start, @previous_end)
      @debounce = debounce_seconds.clamp(0, 3600).seconds
    end

    # Whether this change has served its full debounce window.
    def ready?(now : Time::Span) : Bool
      (first_seen + debounce) <= now
    end

    # Whether the coalesced result still describes a real change.
    def changed? : Bool
      return true if (previous = previous_start) && previous != current_start
      return true if (previous = previous_end) && previous != current_end
      false
    end

    # Advance to the latest signal in the burst.
    def merge(change : PendingChange) : Nil
      @host = change.host
      @title = change.title
      @current_start = change.current_start
      @current_end = change.current_end
    end
  end

  # A staff/event/changed change awaiting its flush.
  class PendingEventChange < PendingChange
    property event_id : String
    property system_id : String # the room the event sits in
    property event_ical_uid : String?
    property previous_system_id : String? # the room before the edit

    def initialize(
      debounce_seconds : Int32,
      @event_id,
      @system_id,
      @event_ical_uid,
      host,
      title,
      current_start,
      current_end,
      previous_start,
      previous_end,
      @previous_system_id,
    )
      super(debounce_seconds, host, title, current_start, current_end, previous_start, previous_end)
      # ical_uid identifies the event instance across mailbox copies and rooms,
      # so the rooms either side of a move coalesce too; the one email then names
      # a single room and uses that room's guest list. event_id is only a
      # fallback for a signal that omits it.
      @buffer_key = "event\t#{@event_ical_uid.presence || @event_id}"
    end

    # Whether this signal reports the event changing rooms.
    def moved_room? : Bool
      !!previous_system_id.try { |previous| previous != system_id }
    end

    def changed? : Bool
      moved_room? || super
    end

    # The room only moves when a signal reports the move, so a same-room echo
    # from another mailbox can't steal it back.
    def merge(change : PendingChange) : Nil
      super
      return unless change.is_a?(PendingEventChange)

      if change.moved_room?
        @event_id = change.event_id
        @system_id = change.system_id
        @previous_system_id ||= change.previous_system_id
      end
      @event_ical_uid = change.event_ical_uid || @event_ical_uid
    end
  end

  # A staff/booking/changed change awaiting its flush.
  class PendingBookingChange < PendingChange
    property booking_id : Int64
    property booking_type : String
    property resource_id : String
    property zones : Array(String)?
    property previous_zones : Array(String)?

    def initialize(
      debounce_seconds : Int32,
      @booking_id,
      @booking_type,
      host,
      title,
      @resource_id,
      current_start,
      current_end,
      previous_start,
      previous_end,
      @zones,
      @previous_zones,
    )
      super(debounce_seconds, host, title, current_start, current_end, previous_start, previous_end)
      @buffer_key = "booking\t#{@booking_id}"
    end

    # Whether this signal reports the booking changing location.
    def moved_zones? : Bool
      !!previous_zones.try { |previous| previous.sort != (zones || [] of String).sort }
    end

    def changed? : Bool
      moved_zones? || super
    end

    def merge(change : PendingChange) : Nil
      super
      return unless change.is_a?(PendingBookingChange)

      @booking_type = change.booking_type
      @resource_id = change.resource_id
      if change.moved_zones?
        @zones = change.zones
        @previous_zones ||= change.previous_zones
      end
    end
  end

  #                      zone_id,     timeout, zone
  alias ZoneCache = Hash(String, Tuple(Int64, ZoneDetails))

  class SystemDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property map_id : String?
    property zones : Array(String)?
  end

  protected def get_room_details(system_id : String, retries = 0)
    SystemDetails.from_json staff_api.get_system(system_id).get_json
  rescue
    raise "issue loading system details #{system_id}" if retries > 3
    sleep 1.second
    get_room_details(system_id, retries + 1)
  end

  # Back-fills an event's start time from the staff API when a
  # staff/event/changed signal omits it (e.g. metadata-only updates). Returns
  # nil on failure so callers can still send without a date rather than crash.
  protected def lookup_event_start(event_id : String, system_id : String) : Int64?
    staff_api.get_event(event_id, system_id).get["event_start"]?.try(&.as_i64?)
  rescue error
    logger.warn(exception: error) { "failed to look up start time for event #{event_id}" }
    nil
  end

  protected def get_host_name(host_email)
    @determine_host_name_using == "staff-api-driver" ? get_host_name_from_staff_api_driver(host_email) : get_host_name_from_calendar_driver(host_email)
  end

  protected def get_host_name_from_calendar_driver(host_email)
    calendar.get_user(host_email).get["name"]
  rescue
    logger.error { "issue loading host details #{host_email}" }
    "your host"
  end

  protected def get_host_name_from_staff_api_driver(host_email, retries = 0)
    staff_api.staff_details(host_email).get["name"].as_s.split('(')[0]
  rescue
    if retries > 3
      logger.error { "issue loading host details #{host_email}" }
      return "your host"
    end
    sleep 1.second
    get_host_name_from_staff_api_driver(host_email, retries + 1)
  end

  # For Cisco ISE network credentials

  def update_network_user_password(user_email : String, password : String, network_group_ids : Array(String) = [] of String)
    # Check if they already exist
    response = network_provider.update_internal_user_password_by_name(user_email, password).get
    logger.debug { "Response from Network Identity provider for lookup of #{user_email} was:\n#{response}" } if @debug
  rescue # todo: catch the specific error where the user already exists, instead of any error. Catch other errors in seperate rescue
    # Create them if they don't already exist
    create_network_user(user_email, password, network_group_ids)
  else
    {user_email, password}
  end

  def create_network_user(user_email : String, password : String, group_ids : Array(String) = [] of String)
    response = network_provider.create_internal_user(email: user_email, name: user_email, password: password, identity_groups: group_ids).get
    logger.debug { "Response from Network Identity provider for creating user #{user_email} was:\n #{response}\n\nDetails:\n#{response.inspect}" } if @debug
    {response["name"], password}
  end
end
