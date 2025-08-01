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

    send_reminders:                     "0 7 * * *",
    reminder_template:                  "visitor",
    event_template:                     "event",
    booking_template:                   "booking",
    notify_checkin_template:            "notify_checkin",
    notify_induction_accepted_template: "induction_accepted",
    notify_induction_declined_template: "induction_declined",
    group_event_template:               "group_event",
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
    host_domain_filter:                 [] of String,

    disable_event_visitors: true,
    invite_zone_tag:        "building",
    is_campus:              false,

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

  @reminder_template : String = "visitor"
  @send_reminders : String? = nil
  @event_template : String = "event"
  @booking_template : String = "booking"
  @notify_checkin_template : String = "notify_checkin"
  @notify_induction_accepted_template : String = "induction_accepted"
  @notify_induction_declined_template : String = "induction_declined"
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

  @uri : URI = URI.new
  @jwt_private_key : String = PlaceOS::Model::JWTBase.private_key

  def on_update
    @debug = setting?(Bool, :debug) || true
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @send_reminders = setting?(String, :send_reminders).presence
    @reminder_template = setting?(String, :reminder_template) || "visitor"
    @event_template = setting?(String, :event_template) || "event"
    @booking_template = setting?(String, :booking_template) || "booking"
    @notify_checkin_template = setting?(String, :notify_checkin_template) || "notify_checkin"
    @notify_induction_accepted_template = setting?(String, :induction_accepted) || "induction_accepted"
    @notify_induction_declined_template = setting?(String, :induction_declined) || "induction_declined"
    @group_event_template = setting?(String, :group_event_template) || "group_event"
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
    @invite_zone_tag = setting?(String, :invite_zone_tag) || "building"
    @is_parent_zone = setting?(Bool, :is_campus) || false

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @booking_space_name = setting?(String, :booking_space_name).presence || "Client Floor"


    @uri = URI.parse(setting?(String, :domain_uri) || "")
    @jwt_private_key = setting?(String, :jwt_private_key) || PlaceOS::Model::JWTBase.private_key

    zones = config.control_system.not_nil!.zones
    schedule.clear
    if reminders = @send_reminders
      schedule.cron(reminders, @time_zone) { send_reminder_emails }
    end
    spawn { ensure_building_zone(zones) }
  end

  def control_system_zone_list
    config.control_system.not_nil!.zones
  end

  protected def ensure_building_zone(zones) : Nil
    find_building(zones)
  rescue error
    logger.warn(exception: error) { "error looking up building zone" }
    schedule.in(5.seconds) { ensure_building_zone(zones) }
  end

  protected def find_building(zones : Array(String)) : ZoneDetails
    zones.each do |zone_id|
      zone = ZoneDetails.from_json staff_api.zone(zone_id).get.to_json
      if zone.tags.includes?(@invite_zone_tag)
        @building_zone = zone
        if @is_parent_zone && (child_zones = Array(ZoneDetails).from_json(staff_api.zones(parent: zone_id).get.to_json))
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

    # don't email staff members
    if !@host_domain_filter.empty? && guest_details.attendee_email.split('@', 2)[1].downcase.in?(@host_domain_filter)
      logger.debug { "ignoring event matches host domain filter" }
      return
    end

    case guest_details
    in GuestCheckin
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
      booking = staff_api.get_booking(guest_details.booking_id).get

      # check if this is actually an event guest (visitor booking with a linked event)
      if linked_event = booking["linked_event"]?
        return if @disable_event_visitors
        room = get_room_details(linked_event.as_h["system_id"].as_s)
        area_name = room.display_name.presence || room.name
        template = @event_template
      else
        area_name = @booking_space_name
        template = @booking_template
      end
      template = @group_event_template if booking["booking_type"].as_s == "group-event"
    in GuestNotification
      # should never get here
      return
    end

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
    event_start : Int64
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
    }
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
    induction_status : Induction
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
    }
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
        description: "Initial invitation for a visitor with a space booking",
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
    ]
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
    kiosk_url = "/visitor-kiosk/#/checkin/preferences?email=#{visitor_email}&jwt=#{guest_jwt}&event_id=#{event_id}"

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
      attach
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

    guests.uniq! { |g| g["email"].as_s.downcase }
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
      scope: ["guest"],
      sub:   guest_id,
      u:     {
        n: name,
        e: email,
        p: 0,
        r: [event_id, system_id],
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

  class SystemDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property map_id : String?
  end

  protected def get_room_details(system_id : String, retries = 0)
    SystemDetails.from_json staff_api.get_system(system_id).get.to_json
  rescue error
    raise "issue loading system details #{system_id}" if retries > 3
    sleep 1.second
    get_room_details(system_id, retries + 1)
  end

  protected def get_host_name(host_email)
    @determine_host_name_using == "staff-api-driver" ? get_host_name_from_staff_api_driver(host_email) : get_host_name_from_calendar_driver(host_email)
  end

  protected def get_host_name_from_calendar_driver(host_email)
    calendar.get_user(host_email).get["name"]
  rescue error
    logger.error { "issue loading host details #{host_email}" }
    return "your host"
  end

  protected def get_host_name_from_staff_api_driver(host_email, retries = 0)
    staff_api.staff_details(host_email).get["name"].as_s.split('(')[0]
  rescue error
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
