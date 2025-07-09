require "placeos-driver"
require "place_calendar"
require "jwt"
require "uri"

# https://developers.zoom.us/docs/meeting-sdk/auth/

class Zoom::Meeting < PlaceOS::Driver
  descriptive_name "Zoom Meeting"
  generic_name :Zoom

  default_settings({
    sdk_key:     "key",
    sdk_secret:  "secret",
    zoom_domain: "x.zoom.us",
  })

  accessor bookings : Bookings_1
  bind Bookings_1, :current_booking, :current_booking_changed

  @key : String = "key"
  @secret : String = "secret"

  getter zoom_domain : String = "x.zoom.us"

  def on_update
    @key = setting(String, :sdk_key)
    @secret = setting(String, :sdk_secret)
    @zoom_domain = setting(String, :zoom_domain).downcase
  end

  enum Role
    Participant = 0
    Host
  end

  @[Security(Level::Administrator)]
  def generate_jwt(meeting_number : String, issued_at : Int64? = nil, expires_at : Int64? = nil, role : Role? = nil)
    iat = issued_at || 2.minutes.ago.to_unix     # issued at time, 2 minutes earlier to avoid clock skew
    exp = expires_at || 2.hours.from_now.to_unix # token expires after 2 hours

    payload = {
      "appKey"   => @key,
      "sdkKey"   => @key,
      "mn"       => meeting_number,
      "role"     => (role || Role::Participant).to_i,
      "tokenExp" => exp,
      "iat"      => iat,
      "exp"      => exp,
    }

    JWT.encode(payload, @secret, JWT::Algorithm::HS256)
  end

  @[Security(Level::Administrator)]
  def get_meeting(start_time : Int64? = nil)
    meeting = if start_time
                bookings.status(Array(PlaceCalendar::Event), :bookings).find { |event| event.event_start == start_time }
              else
                bookings.status?(PlaceCalendar::Event, :current_booking)
              end

    if meeting.nil?
      logger.debug { "no meeting found" }
      return
    end

    # process the meeting body for the zoom link
    logger.debug { "found matching meeting: #{meeting.title}" }
    uri = extract_zoom_link(meeting)

    if uri.nil?
      logger.debug { "no zoom uri found" }
      return
    end

    logger.debug { "found zoom meeting uri: #{uri}" }

    query_params = uri.query_params
    token = query_params["tk"]?.try(&.presence)
    password = query_params["pwd"]?.try(&.presence)
    meeting_id = uri.path.split('/')[2]
    control_sys = config.control_system.not_nil!

    role = @zoom_domain == uri.host.try(&.downcase) ? Role::Host : Role::Participant

    {
      meetingNumber: meeting_id,
      signature:     generate_jwt(meeting_id, role: role),
      userEmail:     control_sys.email,
      userName:      control_sys.display_name.presence || control_sys.name,
      password:      password,
      sdkKey:        @key,
      tk:            token,
    }
  end

  private def extract_zoom_link(event : PlaceCalendar::Event) : URI?
    body = event.body
    return nil unless body

    regex = Regex.new("https://#{Regex.escape(@zoom_domain)}/[jw]/\\d+[^ \\n]*", Regex::Options::IGNORE_CASE)
    link = body.scan(regex).map { |m| m[0] }.first?
    return nil unless link

    URI.parse(link)
  end

  private def current_booking_changed(_subscription, new_event)
    logger.debug { "current booking changed!" }
    event = (PlaceCalendar::Event?).from_json(new_event)
    has_link = extract_zoom_link(event) if event

    self[:meeting_in_progress] = !!has_link
  rescue e
    logger.warn(exception: e) { "failed to parse event" }
    self[:meeting_in_progress] = false
  end
end
