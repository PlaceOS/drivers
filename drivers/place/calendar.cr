module Place; end

require "place_calendar"

class Place::Calendar < PlaceOS::Driver
  descriptive_name "PlaceOS Calendar"
  generic_name :Calendar

  uri_base "https://staff.app.api.com"

  alias GoogleParams = NamedTuple(
    scopes: String | Array(String),
    domain: String,
    sub: String,
    issuer: String,
    signing_key: String,
  )

  alias OfficeParams = NamedTuple(
    tenant: String,
    client_id: String,
    client_secret: String,
  )

  @client : PlaceCalendar::Client? = nil
  @service_account : String = ""

  def on_load
    on_update
  end

  def on_update
    # Work around crystal limitation of splatting a union
    @client = begin
      config = setting(GoogleParams, :calendar_config)
      PlaceCalendar::Client.new(**config)
    rescue
      config = setting(OfficeParams, :calendar_config)
      PlaceCalendar::Client.new(**config)
    end
    @service_account = setting(String, :calendar_service_account)
  end

  protected def client : PlaceCalendar::Client
    @client.not_nil!
  end

  @[Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil)
    client.list_users(query, limit)
  end

  @[Security(Level::Support)]
  def get_user(user_id : String)
    client.get_user(user_id)
  end

  @[Security(Level::Support)]
  def list_calendars(user_id : String)
    client.list_calendars(user_id)
  end

  @[Security(Level::Support)]
  def list_events(calendar_id : String, period_start : Int64, period_end : Int64, time_zone : String? = nil, user_id : String? = nil)
    location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
    period_start = Time.unix(period_start).in location
    period_end = Time.unix(period_end).in location
    user_id = user_id || @service_account

    client.list_events(user_id, calendar_id,
      period_start: period_start,
      period_end: period_end
    )
  end

  @[Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil)
    user_id = user_id || @service_account

    client.delete_event(user_id, event_id, calendar_id: calendar_id)
  end
end
