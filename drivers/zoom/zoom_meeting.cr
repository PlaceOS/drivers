require "placeos-driver"
require "place_calendar"
require "jwt"
require "uri"

# https://developers.zoom.us/docs/meeting-sdk/auth/

class Zoom::Meeting < PlaceOS::Driver
  descriptive_name "Zoom Room"
  generic_name :Zoom

  default_settings({
    zoom_domain:      "x.zoom.us",
    zoom_room_id:     "room_id",
    _zoom_api_system: "sys-management",
  })

  accessor bookings : Bookings_1
  bind Bookings_1, :current_booking, :current_booking_changed

  @zoom_api_system : String? = nil

  getter zoom_domain : String = "x.zoom.us"
  getter room_id : String = ""

  def on_update
    @zoom_domain = setting(String, :zoom_domain).downcase
    @room_id = setting(String, :zoom_room_id)
    @zoom_api_system = setting?(String, :zoom_api_system).presence
  end

  private def zoom_api
    if zoom_system = @zoom_api_system
      system(zoom_system)["ZoomAPI"]
    else
      system["ZoomAPI"]
    end
  end

  struct Meeting
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter uri : URI
    getter url : String
    getter title : String?
    getter event_start : Int64
    getter? is_zoom : Bool
    getter? can_host : Bool

    def id
      uri.path.split('/')[2] if is_zoom?
    end

    def password
      uri.query_params["pwd"]?.try(&.presence) if is_zoom?
    end

    def token
      uri.query_params["tk"]?.try(&.presence) if is_zoom?
    end

    def initialize(@title, @event_start, @is_zoom, @uri, host_domain : String)
      @url = @uri.to_s
      @can_host = @is_zoom ? @url.starts_with?("https://#{host_domain}") : false
    end
  end

  getter current_meeting : Meeting? = nil
  getter joined_meeting : Meeting? = nil

  def join_meeting(start_time : Int64? = nil)
    if start_time
      if event = bookings.status(Array(PlaceCalendar::Event), :bookings).find { |event| event.event_start.to_unix == start_time }
        meeting = extract_meeting(event)
      end
    elsif @current_meeting
      meeting = @current_meeting
    elsif event = bookings.status?(PlaceCalendar::Event, :current_booking)
      meeting = extract_meeting(event)
    end

    if meeting.nil?
      logger.debug { "no meeting found @ #{start_time.inspect}" }
      return
    end

    @joined_meeting = nil

    # process the meeting body for the zoom link
    logger.debug { "found matching meeting: #{meeting.title} - starting #{meeting.event_start}" }

    if meeting.is_zoom?
      logger.debug { "found zoom meeting uri: #{meeting.url} (can host: #{meeting.can_host?})" }

      control_sys = config.control_system.not_nil!
      role = meeting.can_host? ? "host" : "participant"
      meeting_id = meeting.id.as(String)
      password = meeting.password

      zoom_api.meeting_join(room_id, meeting_id, password, meeting.can_host?).get
      @joined_meeting = meeting
      self[:meeting_joined] = meeting.event_start
      spawn { setup_room }

      # https://developers.zoom.us/docs/meeting-sdk/web/component-view/meetings/
      {
        "meetingNumber" => meeting_id,
        "signature"     => zoom_api.generate_jwt(meeting_id, role: role).get.as_s,
        "userEmail"     => control_sys.email,
        "userName"      => control_sys.display_name.presence || control_sys.name,
        "password"      => password || "",
        # sdkKey:      client_id.as_s, # now pulled from the JWT
        "tk" => meeting.token,
      }.compact!
    else
      logger.debug { "found 3rd party meeting uri: #{meeting.url}" }
      zoom_api.meeting_join_thirdparty(room_id, meeting.url).get
      self[:meeting_joined] = meeting.event_start
      nil
    end
  end

  protected def setup_room
    mic_mute false
    camera_mute false
    share_content false
    self[:recording] = Recording::Stop
  end

  def leave_meeting : Nil
    zoom_api.meeting_leave(room_id).get
    @joined_meeting = nil
    self[:meeting_joined] = nil
  end

  def end_meeting : Nil
    zoom_api.meeting_end(room_id).get
    @joined_meeting = nil
    self[:meeting_joined] = nil
  end

  def mic_mute(state : Bool = true) : Bool
    zoom_api.mute(room_id, state).get
    self[:mic_mute] = state
  end

  def camera_mute(state : Bool = true) : Bool
    zoom_api.video_mute(room_id, state).get
    self[:camera_mute] = state
  end

  def share_content(state : Bool = true) : Bool
    zoom_api.share_content(room_id, state).get
    self[:share_content] = state
  end

  def volume(level : Int32) : Int32
    level = level.clamp(0, 100)
    zoom_api.set_volume(room_id, level).get
    self[:volume] = level
  end

  enum Recording
    Start
    Stop
    Pause
    Resume
  end

  def recording(command : Recording) : Recording
    if command.start? && status?(Recording, :recording).try(&.pause?)
      command = Recording::Resume
    end

    in_meeting = joined_meeting || current_meeting
    raise "no live meetings" unless in_meeting
    zoom_api.meeting_recording(in_meeting.id, command).get
    self[:recording] = command.resume? ? Recording::Start : command
  end

  def call_phone(invitee_name : String, phone_number : String) : Nil
    in_meeting = joined_meeting || current_meeting
    raise "no live meetings" unless in_meeting
    zoom_api.meeting_call_phone(in_meeting.id, invitee_name, phone_number).get
  end

  def invite_contacts(emails : String | Array(String)) : Nil
    in_meeting = joined_meeting || current_meeting
    raise "no live meetings" unless in_meeting
    zoom_api.meeting_invite_contacts(in_meeting.id, emails).get
  end

  protected def extract_meeting_links(mail_body : String) : Tuple(Bool, URI)?
    zoom = true
    link = extract_zoom_link(mail_body)

    if link.nil?
      zoom = false
      link = extract_teams_link(mail_body) || extract_meet_link(mail_body)
    end

    return nil unless link
    {zoom, URI.parse(URI.decode(link))}
  end

  def extract_zoom_link(body : String) : String?
    body.scan(/https:\/\/[\w.-]+\.zoom\.us\/[jw]\/\d+[^\s>"]*/i).first?.to_s
  end

  def extract_meet_link(body : String) : String?
    body.scan(/https:\/\/meet\.google\.com\/[^\s>"]+/i).map(&.[0]).first?.to_s
  end

  def extract_teams_link(body : String) : String?
    body.scan(/https:\/\/(?:[\w.-]*teams\.microsoft\.com|teams\.live\.com)\/[^\s>"]+/i).map(&.[0]).first?.to_s
  end

  private def current_booking_changed(_subscription, new_event)
    logger.debug { "current booking changed!" }
    event = (PlaceCalendar::Event?).from_json(new_event)

    if event
      meeting_link = extract_meeting(event)
    end

    @current_meeting = meeting_link
    self[:meeting_in_progress] = meeting_link.try(&.event_start)
  rescue e
    logger.warn(exception: e) { "failed to parse event" }
    self[:meeting_in_progress] = nil
  end

  private def extract_meeting(event : PlaceCalendar::Event) : Meeting?
    if body = event.body
      if extracted = extract_meeting_links(body)
        Meeting.new(event.title, event.event_start.to_unix, *extracted, @zoom_domain)
      end
    end
  end
end
