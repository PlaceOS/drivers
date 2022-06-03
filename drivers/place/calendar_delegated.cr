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
  })

  @api_key : String = ""

  private getter! limiter : RateLimiter::Limiter

  def on_load
    on_update
  end

  def on_update
    rate_limit = setting?(Float64, :rate_limit) || 3.0
    @limiter = RateLimiter.new(rate: rate_limit, max_burst: rate_limit.to_i)

    @api_key = api_key = setting(String, :api_key)
    transport.before_request do |request|
      request.headers["X-API-Key"] = api_key
    end
  end

  protected def client
    limiter.get! max_wait: 90.seconds
    self
  end

  protected def process(response)
    raise "request failed with #{response.status_code} (#{response.body})" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def get_groups(user_id : String)
    logger.debug { "getting group membership for user: #{user_id}" }
    process client.get("/api/staff/v1/people/#{user_id}/groups")
  end

  @[Security(Level::Support)]
  def get_members(group_id : String)
    logger.debug { "listing members of group: #{group_id}" }
    process client.get("/api/staff/v1/groups/#{group_id}/members")
  end

  @[Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil)
    logger.debug { "listing user details, query #{query}" }
    params = query ? {"q" => query} : {} of String => String?
    process client.get("/api/staff/v1/people", params: params)
  end

  @[Security(Level::Support)]
  def get_user(user_id : String)
    logger.debug { "getting user details for #{user_id}" }
    process client.get("/api/staff/v1/people/#{user_id}")
  end

  @[Security(Level::Support)]
  def list_calendars(user_id : String)
    logger.debug { "listing calendars for #{user_id}" }
    process client.get("/api/staff/v1/people/#{user_id}/calendars")
  end

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_user_manager(user_id : String)
    logger.debug { "getting manager details for #{user_id}, note: graphAPI only" }
    process client.get("/api/staff/v1/people/#{user_id}/manager")
  end

  # NOTE:: GraphAPI Only! - here for use with configuration
  @[Security(Level::Support)]
  def list_groups(query : String? = nil)
    logger.debug { "listing groups, filtering by #{query}, note: graphAPI only" }
    params = query ? {"q" => query} : {} of String => String?
    process client.get("/api/staff/v1/groups", params: params)
  end

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_group(group_id : String)
    logger.debug { "getting group #{group_id}, note: graphAPI only" }
    process client.get("/api/staff/v1/groups/#{group_id}")
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
      result.find { |response| response[:email].try(&.downcase) == email }.try &.[](:id)
    end
  end

  @[Security(Level::Support)]
  def list_events(
    calendar_id : String,
    period_start : Int64,
    period_end : Int64,
    time_zone : String? = nil,
    user_id : String? = nil,
    include_cancelled : Bool = false
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
    process client.get("/api/staff/v1/events", params: params)
  end

  @[Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false)
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
        process client.post("/api/staff/v1/events/#{event_id}/decline", params: params)
      rescue
        process client.delete("/api/staff/v1/events/#{event_id}", params: params)
      end
    else
      params["notify"] = "false"
      process client.delete("/api/staff/v1/events/#{event_id}", params: params)
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
    online_meeting_pin : String? = nil
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

    process client.post("/api/staff/v1/events", body: event.to_json)
  end
end
