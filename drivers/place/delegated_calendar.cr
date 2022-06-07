require "placeos-driver"
require "place_calendar"
require "rate_limiter"

class Place::DelegatedCalendar < PlaceOS::Driver
  descriptive_name "PlaceOS Calendar (delegated)"
  generic_name :Calendar

  uri_base "https://staff.app.api.com"

  default_settings({
    # PlaceOS X-API-key
    api_key:    "",
    rate_limit: 5,
  })

  @api_key : String = ""
  @service_account : String? = nil

  private getter! limiter : RateLimiter

  def on_load
    on_update
  end

  def on_update
    if proxy_config = setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy)
      ConnectProxy.proxy_uri = "http://#{proxy_config[:host]}:#{proxy_config[:port]}"
      if proxy_auth = proxy_config[:auth]
        ConnectProxy.username = proxy_auth[:username]
        ConnectProxy.password = proxy_auth[:password]
      end
    end

    ConnectProxy.verify_tls = !!setting?(Bool, :proxy_verify_tls)
    ConnectProxy.disable_crl_checks = !!setting?(Bool, :proxy_disable_crl)

    @service_account = setting?(String, :calendar_service_account).presence

    rate_limit = setting?(Float64, :rate_limit) || 3.0
    @limiter = RateLimiter.new(rate: rate_limit, max_burst: rate_limit.to_i)

    @api_key = setting?(String, :api_key)
  end

  protected def client
    limiter.get! max_wait: 90.seconds
    yield @client.not_nil!
  end

  @[Security(Level::Administrator)]
  def access_token(user_id : String? = nil)
    logger.info { "access token requested #{user_id}" }
    client &.access_token(user_id)
  end

  @[Security(Level::Support)]
  def get_groups(user_id : String)
    logger.debug { "getting group membership for user: #{user_id}" }
    client &.get_groups(user_id)
  end

  @[Security(Level::Support)]
  def get_members(group_id : String)
    logger.debug { "listing members of group: #{group_id}" }
    client &.get_members(group_id)
  end

  @[Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil)
    logger.debug { "listing user details, query #{query}" }
    client &.list_users(query, limit)
  end

  @[Security(Level::Support)]
  def get_user(user_id : String)
    logger.debug { "getting user details for #{user_id}" }
    client &.get_user_by_email(user_id)
  end

  @[Security(Level::Support)]
  def list_calendars(user_id : String)
    logger.debug { "listing calendars for #{user_id}" }
    client &.list_calendars(user_id)
  end

  @[Security(Level::Support)]
  def list_events(calendar_id : String, period_start : Int64, period_end : Int64, time_zone : String? = nil, user_id : String? = nil, include_cancelled : Bool = false)
    location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
    period_start = Time.unix(period_start).in location
    period_end = Time.unix(period_end).in location
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "listing events for #{calendar_id}" }

    client &.list_events(user_id, calendar_id,
      period_start: period_start,
      period_end: period_end,
      showDeleted: include_cancelled
    )
  end

  @[Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "deleting event #{event_id} on #{calendar_id}" }

    client &.delete_event(user_id, event_id, calendar_id: calendar_id, notify: notify)
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
    online_meeting_pin : String? = nil
  )
    user_id = (user_id || @service_account.presence || calendar_id).not_nil!
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

    client &.create_event(user_id, event, calendar_id)
  end
end
