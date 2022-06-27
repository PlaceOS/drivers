require "placeos-driver"
require "place_calendar"
require "rate_limiter"

class Place::CalendarDelegated < PlaceOS::Driver
  descriptive_name "PlaceOS Calendar (delegating to Staff API)"
  generic_name :Calendar

  uri_base "https://staff.app.api.com"

  default_settings({
    # PlaceOS X-API-key
    api_key:    "key-here",
    rate_limit: 5,

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

  @api_key : String = ""
  @host : String = ""
  @jwt_private_key : String = ""

  private getter! limiter : RateLimiter::Limiter

  def on_load
    on_update
  end

  def on_update
    rate_limit = setting?(Float64, :rate_limit) || 3.0
    @limiter = RateLimiter.new(rate: rate_limit, max_burst: rate_limit.to_i)

    @api_key = api_key = setting(String, :api_key)
    transport.before_request do |request|
      request.headers["X-API-Key"] = api_key unless request.headers["Authorization"]?
    end

    @host = URI.parse(config.uri.not_nil!).host.not_nil!
    @debug_payload = setting?(Bool, :debug_payload) || false
    @jwt_private_key = setting?(String, :jwt_private_key) || ""
  end

  protected def client(skip_limiter)
    limiter.get!(max_wait: 90.seconds) unless skip_limiter
    self
  end

  protected def process(response)
    raise "request failed with #{response.status_code} (#{response.body})" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def get_groups(user_id : String, act_as_user : String? = nil)
    logger.debug { "getting group membership for user: #{user_id}" }
    process client(act_as_user).get("/api/staff/v1/people/#{user_id}/groups", headers: act_as(act_as_user))
  end

  @[Security(Level::Support)]
  def get_members(group_id : String, act_as_user : String? = nil)
    logger.debug { "listing members of group: #{group_id}" }
    process client(act_as_user).get("/api/staff/v1/groups/#{group_id}/members", headers: act_as(act_as_user))
  end

  @[Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil, act_as_user : String? = nil)
    logger.debug { "listing user details, query #{query}" }
    params = query ? {"q" => query} : {} of String => String?
    process client(act_as_user).get("/api/staff/v1/people", params: params, headers: act_as(act_as_user))
  end

  @[Security(Level::Support)]
  def get_user(user_id : String, act_as_user : String? = nil)
    logger.debug { "getting user details for #{user_id}" }
    process client(act_as_user).get("/api/staff/v1/people/#{user_id}", headers: act_as(act_as_user))
  end

  @[Security(Level::Support)]
  def list_calendars(user_id : String, act_as_user : String? = nil)
    logger.debug { "listing calendars for #{user_id}" }
    process client(act_as_user).get("/api/staff/v1/people/#{user_id}/calendars", headers: act_as(act_as_user))
  end

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_user_manager(user_id : String, act_as_user : String? = nil)
    logger.debug { "getting manager details for #{user_id}, note: graphAPI only" }
    process client(act_as_user).get("/api/staff/v1/people/#{user_id}/manager", headers: act_as(act_as_user))
  end

  # NOTE:: GraphAPI Only! - here for use with configuration
  @[Security(Level::Support)]
  def list_groups(query : String? = nil, act_as_user : String? = nil)
    logger.debug { "listing groups, filtering by #{query}, note: graphAPI only" }
    params = query ? {"q" => query} : {} of String => String?
    process client(act_as_user).get("/api/staff/v1/groups", params: params, headers: act_as(act_as_user))
  end

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_group(group_id : String, act_as_user : String? = nil)
    logger.debug { "getting group #{group_id}, note: graphAPI only" }
    process client(act_as_user).get("/api/staff/v1/groups/#{group_id}", headers: act_as(act_as_user))
  end

  protected def check_if_resource(email)
    # attempt get the system the requested email is in
    # assuming we are using this driver for resource calendars
    email = email.downcase
    response = get("/api/engine/v2/systems/", params: {
      "email" => email,
      "limit" => "1000",
    })
    if response.success?
      result = Array(NamedTuple(id: String, email: String?)).from_json(response.body)
      result.find { |sys| sys[:email].try(&.downcase) == email }.try &.[](:id)
    end
  end

  @[Security(Level::Support)]
  def list_events(
    calendar_id : String,
    period_start : Int64,
    period_end : Int64,
    time_zone : String? = nil,
    user_id : String? = nil,
    include_cancelled : Bool = false,
    act_as_user : String? = nil
  )
    logger.debug { "listing events for #{calendar_id}" }

    # Query the calendar
    if system_id = check_if_resource(calendar_id)
      params = {
        "system_ids" => system_id,
      }
    else
      params = {
        "calendars" => calendar_id,
      }
    end

    params["period_start"] = period_start.to_s
    params["period_end"] = period_end.to_s
    params["include_cancelled"] = "true" if include_cancelled
    process client(act_as_user).get("/api/staff/v1/events", params: params, headers: act_as(act_as_user))
  end

  @[Security(Level::Support)]
  def delete_event(
    calendar_id : String,
    event_id : String,
    user_id : String? = nil,
    notify : Bool = false,
    act_as_user : String? = nil
  )
    logger.debug { "deleting event #{event_id} on #{calendar_id}" }

    # Query the calendar
    if system_id = check_if_resource(calendar_id)
      params = {
        "system_ids" => system_id,
      }
    else
      params = {
        "calendars" => calendar_id,
      }
    end

    if notify
      begin
        process client(act_as_user).post("/api/staff/v1/events/#{event_id}/decline", params: params, headers: act_as(act_as_user))
      rescue
        process client(act_as_user).delete("/api/staff/v1/events/#{event_id}", params: params, headers: act_as(act_as_user))
      end
    else
      params["notify"] = "false"
      process client(act_as_user).delete("/api/staff/v1/events/#{event_id}", params: params, headers: act_as(act_as_user))
    end
  end

  @[Security(Level::Support)]
  def create_event(
    title : String,
    event_start : Int64,
    event_end : Int64? = nil,
    description : String = "",
    attendees : Array(PlaceCalendar::Event::Attendee) = [] of PlaceCalendar::Event::Attendee,
    location : String? = nil,
    timezone : String? = nil,
    user_id : String? = nil,
    calendar_id : String? = nil,
    online_meeting_id : String? = nil,
    online_meeting_provider : String? = nil,
    online_meeting_url : String? = nil,
    online_meeting_sip : String? = nil,
    online_meeting_phones : Array(String)? = nil,
    online_meeting_pin : String? = nil,
    act_as_user : String? = nil
  )
    calendar_id = calendar_id || user_id
    logger.debug { "creating event on #{calendar_id}" }

    event = PlaceCalendar::Event.new(
      host: calendar_id,
      title: title,
      body: description,
      location: location,
      timezone: timezone,
      attendees: attendees,
      online_meeting_id: online_meeting_id,
      online_meeting_url: online_meeting_url,
      online_meeting_sip: online_meeting_sip,
      online_meeting_pin: online_meeting_pin,
      online_meeting_phones: online_meeting_phones,
      online_meeting_provider: online_meeting_provider,
    )

    tz = Time::Location.load(timezone) if timezone
    event.event_start = timezone ? Time.unix(event_start).in tz.not_nil! : Time.unix(event_start)
    event.event_end = timezone ? Time.unix(event_end).in tz.not_nil! : Time.unix(event_end) if event_end
    event.all_day = true unless event_end

    process client(act_as_user).post("/api/staff/v1/events", body: event.to_json, headers: act_as(act_as_user))
  end

  struct User
    include JSON::Serializable

    getter name : String
    getter email : String
    getter id : String
  end

  protected def act_as(user_id : String?)
    return ::HTTP::Headers.new unless user_id
    return ::HTTP::Headers.new if @jwt_private_key.empty?

    response = get("/api/engine/v2/users/#{user_id}")
    raise "error fetching user details: #{response.status} (response.status_code)\n#{response.body}" unless response.success?
    user = User.from_json(response.body)

    logger.debug { "generating JWT for #{user.email}" }

    payload = {
      iss:   "POS",
      iat:   5.minutes.ago.to_unix,
      exp:   10.minutes.from_now.to_unix,
      jti:   UUID.random.to_s,
      aud:   @host,
      scope: ["public"],
      sub:   user.id,
      u:     {
        n: user.name,
        e: user.email,
        p: 0,
        r: [] of String,
      },
    }

    jwt = JWT.encode(payload, @jwt_private_key, JWT::Algorithm::RS256)
    HTTP::Headers{"Authorization" => "Bearer #{jwt}"}
  end
end
