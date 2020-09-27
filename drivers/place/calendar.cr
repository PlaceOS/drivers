module Place; end

require "place_calendar"

class Place::Calendar < PlaceOS::Driver
  descriptive_name "PlaceOS Calendar"
  generic_name :Calendar

  uri_base "https://staff.app.api.com"

  default_settings({
    calendar_service_account: "service_account@email.address",
    calendar_config:          {
      scopes:      ["https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/admin.directory.user.readonly"],
      domain:      "primary.domain.com",
      sub:         "default.service.account@google.com",
      issuer:      "placeos@organisation.iam.gserviceaccount.com",
      signing_key: "PEM encoded private key",
    },
    calendar_config_office: {
      _note_:        "rename to 'calendar_config' for use",
      tenant:        "",
      client_id:     "",
      client_secret: "",
    },
    rate_limit: 5,
  })

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
  @service_account : String? = nil
  @client_lock : Mutex = Mutex.new
  @rate_limit : Int32 = 3
  @channel : Channel(Nil) = Channel(Nil).new(3)

  @queue_lock : Mutex = Mutex.new
  @queue_size = 0
  @wait_time : Time::Span = 300.milliseconds

  def on_load
    spawn { rate_limiter }
    on_update
  end

  def on_update
    @service_account = setting?(String, :calendar_service_account).presence
    @rate_limit = setting?(Int32, :rate_limit) || 3
    @wait_time = 1.second / @rate_limit
    @channel = Channel(Nil).new(@rate_limit)

    @client_lock.synchronize do
      # Work around crystal limitation of splatting a union
      @client = begin
        config = setting(GoogleParams, :calendar_config)
        PlaceCalendar::Client.new(**config)
      rescue
        config = setting(OfficeParams, :calendar_config)
        PlaceCalendar::Client.new(**config)
      end
    end
  end

  protected def client
    if (@wait_time * @queue_size) > 10.seconds
      raise "wait time would be exceeded for API request, #{@queue_size} requests already queued"
    end
    @queue_lock.synchronize { @queue_size += 1 }
    @client_lock.synchronize do
      @channel.receive
      @queue_lock.synchronize { @queue_size -= 1 }
      yield @client.not_nil!
    end
  end

  def queue_size
    @queue_size
  end

  @[Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil)
    logger.debug { "listing user details, query #{query}" }
    client &.list_users(query, limit)
  end

  @[Security(Level::Support)]
  def get_user(user_id : String)
    logger.debug { "getting user details for #{user_id}" }
    client &.get_user(user_id)
  end

  @[Security(Level::Support)]
  def list_calendars(user_id : String)
    logger.debug { "listing calendars for #{user_id}" }
    client &.list_calendars(user_id)
  end

  @[Security(Level::Support)]
  def list_events(calendar_id : String, period_start : Int64, period_end : Int64, time_zone : String? = nil, user_id : String? = nil)
    location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
    period_start = Time.unix(period_start).in location
    period_end = Time.unix(period_end).in location
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "listing events for #{calendar_id}" }

    client &.list_events(user_id, calendar_id,
      period_start: period_start,
      period_end: period_end
    )
  end

  @[Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "deleting event #{event_id} on #{calendar_id}" }

    client &.delete_event(user_id, event_id, calendar_id: calendar_id)
  end

  @[Security(Level::Support)]
  def create_event(
    title : String,
    event_start : Int64,
    event_end : Int64? = nil,
    description : String = "",
    attendees : Array(PlaceCalendar::Event::Attendee) = [] of PlaceCalendar::Event::Attendee,
    timezone : String? = nil,
    user_id : String? = nil,
    calendar_id : String? = nil
  )
    user_id = (user_id || @service_account.presence || calendar_id).not_nil!
    calendar_id = calendar_id || user_id

    logger.debug { "creating event on #{calendar_id}" }

    event = PlaceCalendar::Event.new
    event.host = calendar_id
    event.title = title
    event.body = description
    event.timezone = timezone
    event.attendees = attendees
    event.event_start = Time.unix(event_start)
    if event_end
      event.event_end = Time.unix(event_end)
    else
      event.all_day = true
    end

    client &.create_event(user_id, event, calendar_id)
  end

  protected def rate_limiter
    loop do
      begin
        @channel.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep @wait_time
      end
    end
  end
end
