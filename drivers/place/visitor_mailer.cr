module Place; end

require "uuid"
require "oauth2"
require "placeos-driver/interface/mailer"

class Place::VisitorMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Visitor Mailer"
  generic_name :VisitorMailer
  description %(emails visitors when they are invited and notifies hosts when they check in)

  default_settings({
    timezone:         "GMT",
    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",
  })

  accessor mailer : Mailer_1, implementing: PlaceOS::Driver::Interface::Mailer
  accessor staff_api : StaffAPI_1

  def on_load
    # Guest has been marked as attending a meeting in person
    monitor("staff/guest/attending") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_event(payload.gsub(/[^[:print:]]/, "")) }

    on_update
  end

  @uri : URI? = nil
  @host : String = ""
  @origin : String = ""
  @time_zone : Time::Location = Time::Location.load("GMT")

  @users_checked_in : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  @visitor_emails_sent : UInt64 = 0_u64
  @visitor_email_errors : UInt64 = 0_u64

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  def on_update
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    uri = URI.parse(config.uri.not_nil!)
    @host = uri.port ? "#{uri.host}:#{uri.port}" : uri.host.not_nil!
    @origin = "#{uri.scheme}://#{@host}"
    @uri = uri

    time_zone = setting?(String, :calendar_time_zone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)
  end

  class GuestEvent
    include JSON::Serializable

    property action : String
    property checkin : Bool?
    property system_id : String
    property event_id : String
    property host : String
    property resource : String
    property event_summary : String
    property event_starting : Int64
    property attendee_name : String
    property attendee_email : String
    property ext_data : Hash(String, JSON::Any)?
  end

  protected def guest_event(payload)
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = GuestEvent.from_json payload

    if guest_details.action == "checkin"
      # send_checkedin_email(
      #   guest_details.host,
      #   guest_details.attendee_name,
      # )
      # self[:users_checked_in] = @users_checked_in += 1
    else
      send_visitor_qr_email(
        guest_details.attendee_email,
        guest_details.attendee_name,
        guest_details.host,
        guest_details.event_id,
        # guest_details.event_title,
        guest_details.event_starting,
        guest_details.system_id,
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
    visitor_email : String,
    visitor_name : String,
    host_email : String,
    event_id : String,
    # event_title :   String,
    event_start : Int64,
    system_id : String
  )
    room = get_room_details(system_id)

    local_start_time = Time.unix(event_start).in(@time_zone)

    qr_png = mailer.generate_png_qrcode(text: "VISIT:#{visitor_email},#{system_id},#{event_id},#{host_email}", size: 256).get.as_s

    mailer.send_template(
      visitor_email,
      {"visitor_invited", "visitor"}, # Template selection: "visitor_invited" action, "visitor" email
      {
      visitor_email: visitor_email,
      visitor_name:  visitor_name,
      host_name:     get_host_name(host_email),
      room_name:     room.display_name.presence || room.name,
      # event_title:   event_title,
      event_start: local_start_time.to_s(@time_format),
      event_date:  local_start_time.to_s(@date_format),
    },
      [
        {
          file_name:  "qr.png",
          content:    qr_png,
          content_id: visitor_email,
        },
      ]
    )
  end

  # ===================================
  # PlaceOS API requests
  # ===================================

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
end
