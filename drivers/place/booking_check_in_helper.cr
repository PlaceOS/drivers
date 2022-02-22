require "placeos-driver"
require "place_calendar"

class Place::BookingCheckInHelper < PlaceOS::Driver
  descriptive_name "PlaceOS Check-in helper"
  generic_name :CheckInHelper
  description "works in conjunction with the Bookings driver to help automate check-in"

  accessor bookings : Bookings_1
  accessor staff_api : StaffAPI_1
  accessor mailer : Mailer_1, implementing: PlaceOS::Driver::Interface::Mailer

  default_settings({
    # how many minutes until we want to prompt the user
    prompt_after: 10,
    auto_cancel:  false,

    # how many minutes to wait before we enable auto-check-in
    present_from: 5,

    time_zone:        "Australia/Sydney",
    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",

    # URIs for confirming or denying a meeting
    check_in_url: "https://domain.com/meeting/check-in",
    no_show_url:  "https://domain.com/meeting/no-show",

    jwt_private_key: <<-STRING
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAt01C9NBQrA6Y7wyIZtsyur191SwSL3MjR58RIjZ5SEbSyzMG
3r9v12qka4UtpB2FmON2vwn0fl/7i3Jgh1Xth/s+TqgYXMebdd123wodrbex5pi3
Q7PbQFT6hhNpnsjBh9SubTf+IeTIFeXUyqtqcDBmEoT5GxU6O+Wuch2GtbfEAmaD
roy+uyB7P5DxpKLEx8nlVYgpx5g2mx2LufHvykVnx4bFzLezU93SIEW6yjPwUmv9
R+wDM/AOg60dIf3hCh1DO+h22aKT8D8ysuFodpLTKCToI/AbK4IYOOgyGHZ7xizX
HYXZdsqX5/zBFXu/NOVrSd/QBYYuCxbqe6tz4wIDAQABAoIBAQCEIRxXrmXIcMlK
36TfR7h8paUz6Y2+SGew8/d8yvmH4Q2HzeNw41vyUvvsSVbKC0HHIIfzU3C7O+Lt
9OeiBo2vTKrwNflBv9zPDHHoerlEBLsnNwQ7uEUeTWM9DHdBLwNaLzQApLD6q5iT
OFW4NfIGpsydIt8R565PiNPDjIcTKwhbVdlsSbI87cLkQ9UuYIMRkvXSD1Q2cg3I
VsC0SpE4zmfTe7YTZQ5yTxtsoLKPBXrSxhhGuhdayeN7A4YHFYVD39RuQ6/T2w2a
W/0UaGOk8XWgydDpD5w9wiBdH2I4i6D35IynCcodc5JvmTajzJT+xj6aGjjvMSyq
q5ZdwJ4JAoGBAOPdZgjbOCf3ONUoiZ5Qw/a4b4xJgMokgqZ5QGBF5GqV1Xsphmk1
apYmgC7fmab/EOdycrQMS0am2FmtwX1f7gYgJoyWtK4TVkUc5rf+aoWi0ieIsegv
rjhuiIAc12+vVIbegRgnq8mOI5icrwm6OkwdqHkwTt6VRYdJGEmu67n/AoGBAM3v
RAd5uIjVwVDLXqaOpvF3pxWfl+cf6PJtAE5y+nbabeTmrw//fJMank3o7qCXkFZR
F0OJ2tmENwV+LPM8Gy3So8YP2nkOz4bryaGrxQ4eMA+K9+RiACVaKv+tNx/NbyMS
e9gg504u0cwa60XjM5KUKrmT3RXpY4YIfUPZ1J4dAoGAB6jalDOiSJ2j2G57acn3
PGTowwN5g9IEXko3IsVWr0qIGZLExOaZxaBXsLutc5KhY9ZSCsFbCm3zWdhgZ7GA
083i3dj3C970iHA3RToVJJbbj56ltFNd/OGiTwQpLcTsB3iVSFWVDbpsceXacG5F
JWfd0O0RyaOk6a5IVbm+jMsCgYBglxAOfY4LSE8y6SCM+K3e5iNNZhymgHYPdwbE
xPMrWgpfab/Evi2dBcgofM+oLU663bAOspMeoP/5qJPGxnNtC7ZbSMZNL6AxBVj+
ZoW3uHsMXz8kNL8ixecTIxiO5xlwltPVrKExL46hsCKYFhfzcWGUx4DULTLMBCFU
+M/cFQKBgQC+Ite962yJOnE+bjtSReOrvR9+I+YNGqt7vyRa2nGFxL7ZNIqHss5T
VjaMgjzVJqqYozNT/74pE/b9UjYyMzO/EhrjUmcwriMMan/vTbYoBMYWvGoy536r
4n455vizig2c4/sxU5yu9AF9Dv+qNsGCx2e9uUOTDUlHM9NXwxU9rQ==
-----END RSA PRIVATE KEY-----
STRING
  })

  def on_load
    on_update
  end

  # See: https://crystal-lang.org/api/latest/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"
  @timezone : Time::Location = Time::Location::UTC

  protected getter! prompt_after : Time::Span
  protected getter! present_from : Time::Span
  @auto_cancel : Bool = false

  getter? meeting_pending : Bool = false
  getter? people_present : Bool = false
  getter current_meeting : PlaceCalendar::Event? = nil

  # This last meeting id we prompted
  @prompted : String = ""

  # The URLS we want to send to the user
  @check_in_url : String = ""
  @no_show_url : String = ""
  @domain : String = ""

  @jwt_private_key : String = ""

  def on_update
    @jwt_private_key = setting(String, :jwt_private_key)

    @prompt_after = (setting?(Int32, :prompt_after) || 10).minutes
    @present_from = (setting?(Int32, :present_from) || 5).minutes
    @auto_cancel = setting?(Bool, :auto_cancel) || false

    @check_in_url = setting(String, :check_in_url)
    @no_show_url = setting(String, :no_show_url)
    @domain = URI.parse(@check_in_url).host.not_nil!

    subscriptions.clear
    bookings.subscribe(:current_booking) do |_sub, pending|
      event = PlaceCalendar::Event?.from_json(pending)
      update_current event
    end
    bookings.subscribe(:current_pending) { |_sub, pending| update_pending(pending == "true") }
    bookings.subscribe(:presence) { |_sub, presence| update_presence(presence == "true") }

    monitor("#{config.control_system.not_nil!.id}/guest/bookings/prompted") do |_sub, response|
      prompt_response(**NamedTuple(id: String, check_in: Bool).from_json(response))
    end

    timezone = setting?(String, :time_zone) || config.control_system.not_nil!.timezone.presence
    @timezone = Time::Location.load(timezone) if timezone

    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
  end

  protected def update_current(meeting : PlaceCalendar::Event?)
    logger.debug { "> current meeting: #{!!meeting}" }
    @current_meeting = meeting
    self[:current_meeting] = !!meeting
    meeting ? apply_state_changes : cleanup_state
  end

  protected def update_pending(state : Bool)
    logger.debug { "> meeting pending: #{state}" }
    self[:meeting_pending] = @meeting_pending = state
    state ? apply_state_changes : cleanup_state
  end

  protected def update_presence(state : Bool)
    logger.debug { "> people present: #{state}" }
    self[:people_present] = @people_present = state
    apply_state_changes
  end

  protected def cleanup_state
    logger.debug { "cleaning up state, pending: #{@meeting_pending}, meeting: #{!!@current_meeting}" }
    schedule.clear

    meeting = current_meeting
    if meeting.try(&.id) != @prompted
      self[:prompted] = false
      self[:no_show] = false
      self[:checked_in] = false
      self[:responded] = false
    end
  end

  protected def apply_state_changes
    meeting = self.current_meeting
    return unless meeting && meeting_pending?

    logger.debug { "applying state changes" }
    schedule.clear

    time_now = Time.utc
    start_time = meeting.event_start
    prompt_at = start_time + prompt_after
    check_presence_from = start_time + present_from

    # Can we auto check-in?
    logger.debug { "people_present? #{people_present?}" }
    if people_present?
      if time_now >= check_presence_from
        logger.debug { "starting meeting!" }
        bookings.start_meeting(start_time.to_unix)
      else
        # Schedule an auto check-in check as people_present? might remain high
        logger.debug { "scheduling meeting start" }
        schedule.at(check_presence_from) do
          logger.debug { "starting meeting!" }
          bookings.start_meeting(start_time.to_unix)
        end
      end
      return
    end

    # should we be scheduling a prompt email?
    if time_now >= prompt_at
      logger.debug { "no show, prompting user" }
      prompt_user meeting
    else
      logger.debug { "scheduling no show" }
      schedule.at(prompt_at) do
        logger.debug { "scheduled no show, prompting user" }
        prompt_user meeting
      end
    end
  end

  # sends the templated email to the host for booking confirmation
  protected def prompt_user(meeting : PlaceCalendar::Event)
    if @prompted == meeting.id
      logger.debug { "user has already been prompted" }
      return
    end

    logger.debug { "prompting user about meeting room booking #{meeting.id}" }
    params = generate_guest_jwt
    mailer.send_template(params[:host_email], {"bookings", "check_in_prompt"}, params)

    @prompted = meeting.id.not_nil!
    self[:no_show] = false
    self[:checked_in] = false
    self[:responded] = false
    self[:prompted] = true

    prompt_response(meeting.id.not_nil!, false) if @auto_cancel
  end

  # processes the response if the user clicks one of the links in the email
  protected def prompt_response(id : String, check_in : Bool)
    meeting = current_meeting
    unless meeting
      logger.warn { "received response but no current meeting" }
      return
    end

    if @prompted == meeting.id && @prompted == id
      self[:responded] = true
      logger.info { "host has responded with #{check_in}" }

      if check_in
        bookings.start_meeting(meeting.event_start.to_unix)
        self[:checked_in] = true
      else
        bookings.end_meeting(meeting.event_start.to_unix)
        self[:no_show] = true
      end
    else
      logger.warn { "received response for another meeting #{id} != #{meeting.id} or #{@prompted}" }
    end
  end

  # generates the parameters that can be mixed into the template email
  protected def generate_guest_jwt
    meeting = current_meeting
    raise "expected current meeting" unless meeting

    ctrl_system = config.control_system.not_nil!
    system_id = ctrl_system.id
    event_id = meeting.id
    host_email = meeting.host.not_nil!
    user = PlaceCalendar::User.from_json staff_api.staff_details(host_email).get.to_json

    now = Time.utc
    starting = meeting.event_start.in(@timezone)
    end_of_meeting = (meeting.event_end || starting.at_end_of_day).in(@timezone)

    payload = {
      iss:   "POS",
      iat:   now.to_unix,
      exp:   end_of_meeting.to_unix,
      jti:   UUID.random.to_s,
      aud:   @domain,
      scope: ["guest"],
      sub:   host_email,
      u:     {
        n: user.name,
        e: host_email,
        p: 0,
        r: [event_id, system_id],
      },
    }

    jwt = JWT.encode(payload, @jwt_private_key, JWT::Algorithm::RS256)

    {
      jwt:               jwt,
      host_email:        host_email,
      host_name:         user.name,
      event_id:          event_id,
      system_id:         system_id,
      meeting_room_name: ctrl_system.display_name.presence || ctrl_system.name,
      meeting_summary:   meeting.title,
      meeting_datetime:  starting.to_s(@date_time_format),
      meeting_time:      starting.to_s(@time_format),
      meeting_date:      starting.to_s(@date_format),
      check_in_url:      @check_in_url,
      no_show_url:       @no_show_url,
    }
  end
end
