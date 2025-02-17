require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"

# required models
require "../wiegand/models"
require "../place/visitor_models"

class InnerRange::IntegritiBookingCheckin < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "Integriti Visitor Access"
  generic_name :VisitorAccess

  default_settings({
    timezone:                  "GMT",
    date_time_format:          "%c",
    time_format:               "%l:%M%p",
    date_format:               "%A, %-d %B",
    visitor_access_template:   "visitor_access",
    determine_host_name_using: "calendar-driver",
  })

  @time_zone : Time::Location = Time::Location.load("GMT")

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  @visitor_access_template : String = "visitor_access"
  @determine_host_name_using : String = "calendar-driver"

  @users_granted_access : UInt64 = 0_u64

  def on_load
    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_checked_in(payload.gsub(/[^[:print:]]/, "")) }
    on_update
  end

  def on_update
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @visitor_access_template = setting?(String, :visitor_access_template) || "visitor_access"
    @determine_host_name_using = setting?(String, :determine_host_name_using) || "calendar-driver"

    time_zone = setting?(String, :timezone).presence || config.control_system.try(&.timezone) || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @control_system_zone_list = nil
    @building_id = nil
    @building_zone = nil
  end

  accessor locations : LocationServices_1
  accessor integriti : Integriti_1
  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  getter control_system_zone_list : Array(String) do
    config.control_system.not_nil!.zones
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  class ZoneDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property location : String?
    property tags : Array(String)
    property parent_id : String?
  end

  getter building_zone : ZoneDetails do
    ZoneDetails.from_json staff_api.zone(building_id).get.to_json
  end

  protected def guest_checked_in(payload)
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = Place::GuestNotification.from_json payload
    zones = guest_details.zones
    return unless zones

    # ensure the event is for this building
    if (config.control_system.not_nil!.zones & zones).empty?
      logger.debug { "ignoring event as does not match any zones" }
      return
    end

    case guest_details
    when Place::GuestCheckin
      grant_and_notify_access(
        guest_details.attendee_email,
        guest_details.attendee_name.as(String),
        guest_details.host.as(String),
        guest_details.event_summary,
        guest_details.event_starting
      )
      self[:users_granted_access] = @users_granted_access += 1
    else
      logger.debug { "ignoring event as not a checkin: #{guest_details.class}" }
    end
  end

  def grant_and_notify_access(
    visitor_email : String,
    visitor_name : String,
    host_email : String,
    event_title : String?,
    event_start : Int64
  )
    local_start_time = Time.unix(event_start).in(@time_zone)
    late_in_day = local_start_time.at_end_of_day - 7.hours

    access_from = (local_start_time - 15.minutes).to_unix
    access_until = local_start_time < late_in_day ? late_in_day : (local_start_time + 2.hours)
    card_details = integriti.grant_guest_access(visitor_name, visitor_email, access_from, access_until).get
    card_facility = card_details["card_facility"].as_i64.to_u32
    card_number = card_details["card_number"].as_i64.to_u32

    # remove the 2 sign bits
    wiegand = Wiegand::Wiegand26.from_components(facility: card_facility, card_number: card_number)
    raw = (wiegand.wiegand & (Wiegand::Wiegand26::FACILITY_MASK | Wiegand::Wiegand26::CARD_MASK)) >> 1
    data = raw.to_s(16).upcase.rjust(6, '0')

    # convert to hex and create QR code
    qr_png = mailer.generate_png_qrcode(text: data, size: 256).get.as_s
    attach = [
      {
        file_name:  "access.png",
        content:    qr_png,
        content_id: visitor_email,
      },
    ]

    mailer.send_template(
      visitor_email,
      {"visitor_invited", @visitor_access_template},
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
      attach
    )
  end

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(@time_zone)

    invitation_fields = [
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

    [
      TemplateFields.new(
        trigger: {"visitor_invited", @visitor_access_template},
        name: "Visitor invited",
        description: "Visitor entry security email with QR code for access",
        fields: invitation_fields
      ),
    ]
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
end
