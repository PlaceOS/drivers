require "placeos-driver"
require "placeos-driver/interface/mailer"

require "uuid"
require "oauth2"

class Place::VisitorMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Visitor Mailer"
  generic_name :VisitorMailer
  description %(emails visitors when they are invited and notifies hosts when they check in)

  default_settings({
    timezone:           "GMT",
    date_time_format:   "%c",
    time_format:        "%l:%M%p",
    date_format:        "%A, %-d %B",
    booking_space_name: "Client Floor",

    send_reminders:                     "0 7 * * *",
    reminder_template:                  "visitor",
    event_template:                     "event",
    booking_template:                   "booking",
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
  })

  accessor staff_api : StaffAPI_1
  accessor mailer : Mailer_1, implementing: PlaceOS::Driver::Interface::Mailer
  accessor network_provider : NetworkAccess_1 # Written for Cisco ISE Driver, but ideally compatible with others

  def on_load
    # Guest has been marked as attending a meeting in person
    monitor("staff/guest/attending") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    on_update
  end

  @time_zone : Time::Location = Time::Location.load("GMT")

  @debug : Bool = false
  @users_checked_in : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  @visitor_emails_sent : UInt64 = 0_u64
  @visitor_email_errors : UInt64 = 0_u64
  @disable_qr_code : Bool = false

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  getter! building_zone : ZoneDetails
  @booking_space_name : String = "Client Floor"

  @reminder_template : String = "visitor"
  @send_reminders : String? = nil
  @event_template : String = "event"
  @booking_template : String = "booking"
  @send_network_credentials = false
  @network_password_length : Int32 = DEFAULT_PASSWORD_LENGTH
  @network_password_exclude : String = DEFAULT_PASSWORD_EXCLUDE
  @network_password_minimum_lowercase : Int32 = DEFAULT_PASSWORD_MINIMUM_LOWERCASE
  @network_password_minimum_uppercase : Int32 = DEFAULT_PASSWORD_MINIMUM_UPPERCASE
  @network_password_minimum_numbers : Int32 = DEFAULT_PASSWORD_MINIMUM_NUMBERS
  @network_password_minimum_symbols : Int32 = DEFAULT_PASSWORD_MINIMUM_SYMBOLS
  @network_group_ids = [] of String

  def on_update
    @debug = setting?(Bool, :debug) || true
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @send_reminders = setting?(String, :send_reminders).presence
    @reminder_template = setting?(String, :reminder_template) || "visitor"
    @event_template = setting?(String, :event_template) || "event"
    @booking_template = setting?(String, :booking_template) || "booking"
    @disable_qr_code = setting?(Bool, :disable_qr_code) || false
    @send_network_credentials = setting?(Bool, :send_network_credentials) || false
    @network_password_length = setting?(Int32, :password_length) || DEFAULT_PASSWORD_LENGTH
    @network_password_exclude = setting?(String, :password_exclude) || DEFAULT_PASSWORD_EXCLUDE
    @network_password_minimum_lowercase = setting?(Int32, :password_minimum_lowercase) || DEFAULT_PASSWORD_MINIMUM_LOWERCASE
    @network_password_minimum_uppercase = setting?(Int32, :password_minimum_uppercase) || DEFAULT_PASSWORD_MINIMUM_UPPERCASE
    @network_password_minimum_numbers = setting?(Int32, :password_minimum_numbers) || DEFAULT_PASSWORD_MINIMUM_NUMBERS
    @network_password_minimum_symbols = setting?(Int32, :password_minimum_symbols) || DEFAULT_PASSWORD_MINIMUM_SYMBOLS
    @network_group_ids = setting?(Array(String), :network_group_ids) || [] of String

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @booking_space_name = setting?(String, :booking_space_name).presence || "Client Floor"

    zones = config.control_system.not_nil!.zones
    schedule.clear
    if reminders = @send_reminders
      schedule.cron(reminders, @time_zone) { send_reminder_emails }
    end
    spawn(same_thread: true) { find_building(zones) }
  end

  protected def find_building(zones : Array(String)) : Nil
    zones.each do |zone_id|
      zone = ZoneDetails.from_json staff_api.zone(zone_id).get.to_json
      if zone.tags.includes?("building")
        @building_zone = zone
        break
      end
    end
    raise "no building zone found in System" unless @building_zone
  rescue error
    logger.warn(exception: error) { "error looking up building zone" }
    schedule.in(5.seconds) { find_building(zones) }
  end

  abstract class GuestNotification
    include JSON::Serializable

    use_json_discriminator "action", {
      "booking_created" => BookingGuest,
      "booking_updated" => BookingGuest,
      "meeting_created" => EventGuest,
      "meeting_update"  => EventGuest,
    }

    property action : String

    property checkin : Bool?
    property event_summary : String
    property event_starting : Int64
    property attendee_name : String?
    property attendee_email : String
    property host : String

    # This is optional for backwards compatibility
    property zones : Array(String)?

    property ext_data : Hash(String, JSON::Any)?
  end

  class EventGuest < GuestNotification
    include JSON::Serializable

    property system_id : String
    property event_id : String
    property resource : String

    def resource_id
      system_id
    end
  end

  class BookingGuest < GuestNotification
    include JSON::Serializable

    property booking_id : Int64
    property resource_id : String

    def event_id
      booking_id.to_s
    end
  end

  protected def guest_event(payload)
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = GuestNotification.from_json payload

    # ensure the event is for this building
    if zones = guest_details.zones
      return unless zones.includes?(building_zone.id)
    end

    if guest_details.action == "checkin"
      # send_checkedin_email(
      #   guest_details.host,
      #   guest_details.attendee_name,
      # )
      # self[:users_checked_in] = @users_checked_in += 1
    else
      case guest_details
      in EventGuest
        room = get_room_details(guest_details.system_id)
        area_name = room.display_name.presence || room.name
        template = @event_template
      in BookingGuest
        area_name = @booking_space_name
        template = @booking_template
      in GuestNotification
        # should never get here
        return
      end

      send_visitor_qr_email(
        template,
        guest_details.attendee_email,
        guest_details.attendee_name,
        guest_details.host,
        guest_details.event_summary,
        guest_details.event_starting,
        guest_details.resource_id,
        guest_details.event_id,
        area_name
      )
    end
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

    event_end : Int64? = nil
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
  # PlaceOS API requests
  # ===================================

  class ZoneDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property location : String?
    property tags : Array(String)
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
    sleep 1
    get_room_details(system_id, retries + 1)
  end

  protected def get_host_name(host_email, retries = 0)
    staff_api.staff_details(host_email).get["name"].as_s.split('(')[0]
  rescue error
    if retries > 3
      logger.error { "issue loading host details #{host_email}" }
      return "your host"
    end
    sleep 1
    get_host_name(host_email, retries + 1)
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
