require "placeos-driver"
require "place_calendar"
require "placeos-driver/interface/mailer"
require "qr-code"
require "qr-code/export/png"

module Place::CalendarCommon
  include PlaceOS::Driver::Interface::Mailer

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
    conference_type: String | Nil,
  )

  macro included
    @client : PlaceCalendar::Client? = nil
    @service_account : String? = nil
    @rate_limit : Int32 = 10
    @channel : Channel(Nil) = Channel(Nil).new(9)
    @in_flight : Channel(Nil) = Channel(Nil).new(10)

    @queue_lock : Mutex = Mutex.new
    @queue_size = 0
    @flight_size = 0
    @wait_time : Time::Span = 300.milliseconds

    @mailer_from : String? = nil
  end

  def on_load
    @channel = Channel(Nil).new(2)
    spawn { rate_limiter }
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
    @rate_limit = setting?(Int32, :rate_limit) || 3
    @wait_time = 1.second / @rate_limit

    @mailer_from = setting?(String, :mailer_from).presence || @service_account
    @templates = setting?(Templates, :email_templates) || Templates.new

    # Work around crystal limitation of splatting a union
    @client = begin
      config = setting(GoogleParams, :calendar_config)
      PlaceCalendar::Client.new(**config)
    rescue
      config = setting(OfficeParams, :calendar_config)
      PlaceCalendar::Client.new(**config)
    end
  end

  protected def client
    # office365 execute queries against the users mailbox and hence doesn't require rate limiting
    if @client.not_nil!.client_id == :office365
      return yield(@client.not_nil!)
    end

    if (@wait_time * @queue_size) > 90.seconds
      raise "wait time would be exceeded for API request, #{@queue_size} requests already queued"
    end

    @queue_lock.synchronize { @queue_size += 1 }
    @channel.receive
    @in_flight.send(nil)

    begin
      @queue_lock.synchronize { @queue_size -= 1; @flight_size += 1 }
      result = yield @client.not_nil!
      result
    ensure
      @in_flight.receive
      @queue_lock.synchronize { @flight_size -= 1 }
    end
  end

  def queue_size
    @queue_size
  end

  def in_flight_size
    @flight_size
  end

  def generate_svg_qrcode(text : String) : String
    QRCode.new(text).as_svg
  end

  def generate_png_qrcode(text : String, size : Int32 = 128) : String
    Base64.strict_encode QRCode.new(text).as_png(size: size)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def send_mail(
    to : String | Array(String),
    subject : String,
    message_plaintext : String? = nil,
    message_html : String? = nil,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  )
    sender = case from
             in String
               from
             in Array(String)
               from.first? || @mailer_from.not_nil!
             in Nil
               @mailer_from.not_nil!
             end

    logger.debug { "an email was sent from: #{sender}, to: #{to}" }

    client &.calendar.send_mail(
      sender,
      to,
      subject,
      message_plaintext,
      message_html,
      resource_attachments,
      attachments,
      cc,
      bcc
    )
  end

  @[PlaceOS::Driver::Security(Level::Administrator)]
  def access_token(user_id : String? = nil)
    logger.info { "access token requested #{user_id}" }
    client &.access_token(user_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_groups(user_id : String)
    logger.debug { "getting group membership for user: #{user_id}" }
    client &.get_groups(user_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_members(group_id : String)
    logger.debug { "listing members of group: #{group_id}" }
    client &.get_members(group_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_users(query : String? = nil, limit : Int32? = nil)
    logger.debug { "listing user details, query #{query}" }
    client &.list_users(query, limit)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_user(user_id : String)
    logger.debug { "getting user details for #{user_id}" }
    client &.get_user_by_email(user_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_calendars(user_id : String)
    logger.debug { "listing calendars for #{user_id}" }
    client &.list_calendars(user_id)
  end

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def get_user_manager(user_id : String)
    logger.debug { "getting manager details for #{user_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.get_user_manager(user_id).to_place_calendar
      end
    end
  end

  # NOTE:: GraphAPI Only! - here for use with configuration
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_groups(query : String? = nil)
    logger.debug { "listing groups, filtering by #{query}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.list_groups(query).value.map(&.to_place_group)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def get_group(group_id : String)
    logger.debug { "getting group #{group_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.get_group(group_id).to_place_group
      end
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_events(calendar_id : String, period_start : Int64, period_end : Int64, time_zone : String? = nil, user_id : String? = nil, include_cancelled : Bool = false)
    location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
    period_start = Time.unix(period_start).in location
    period_end = Time.unix(period_end).in location
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "listing events for #{calendar_id}" }

    _client = @client.not_nil!
    if _client.client_id == :google
      _client.calendar.as(PlaceCalendar::Google).list_events(user_id, calendar_id,
        period_start: period_start,
        period_end: period_end,
        showDeleted: include_cancelled,
        # https://cloud.google.com/apis/docs/system-parameters (avoid hitting request quotas in common driver usage)
        quotaUser: calendar_id[0..39]
      )
    else
      _client.list_events(user_id, calendar_id,
        period_start: period_start,
        period_end: period_end,
        showDeleted: include_cancelled
      )
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "deleting event #{event_id} on #{calendar_id}" }

    client &.delete_event(user_id, event_id, calendar_id: calendar_id, notify: notify)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
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

  protected def rate_limiter
    loop do
      begin
        # ensure there is an available slot before allowing more requests
        @in_flight.send(nil)
        @in_flight.receive

        # allow more requests through
        @channel.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep @wait_time
      end
    end
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter }
  end
end
