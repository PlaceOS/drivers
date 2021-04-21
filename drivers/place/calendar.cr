module Place; end

require "place_calendar"
require "placeos-driver/interface/mailer"
require "qr-code"
require "qr-code/export/png"

class Place::Calendar < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Mailer

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
      conference_type: nil,   # This can be set to "teamsForBusiness" to add a Teams link to EVERY created Event
    },
    rate_limit: 5,

    # defaults to calendar_service_account if not configured
    mailer_from:     "email_or_office_userPrincipalName",
    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
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
    conference_type: String | Nil,
  )

  @client : PlaceCalendar::Client? = nil
  @service_account : String? = nil
  @client_lock : Mutex = Mutex.new
  @rate_limit : Int32 = 3
  @channel : Channel(Nil) = Channel(Nil).new(3)

  @queue_lock : Mutex = Mutex.new
  @queue_size = 0
  @wait_time : Time::Span = 300.milliseconds

  @mailer_from : String? = nil

  def on_load
    @channel = Channel(Nil).new(2)
    spawn { rate_limiter }
    on_update
  end

  def on_update
    @service_account = setting?(String, :calendar_service_account).presence
    @rate_limit = setting?(Int32, :rate_limit) || 3
    @wait_time = 1.second / @rate_limit

    @mailer_from = setting?(String, :mailer_from).presence || @service_account
    @templates = setting?(Templates, :email_templates) || Templates.new

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

  def generate_svg_qrcode(text : String) : String
    QRCode.new(text).as_svg
  end

  def generate_png_qrcode(text : String, size : Int32 = 128) : String
    Base64.strict_encode QRCode.new(text).as_png(size: size)
  end

  @[Security(Level::Support)]
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

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_user_manager(user_id : String)
    logger.debug { "getting manager details for #{user_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.get_user_manager(user_id).to_place_calendar
      end
    end
  end

  # NOTE:: GraphAPI Only! - here for use with configuration
  @[Security(Level::Support)]
  def list_groups(query : String?)
    logger.debug { "listing groups, filtering by #{query}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.list_groups(query)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  @[Security(Level::Support)]
  def get_group(group_id : String)
    logger.debug { "getting group #{group_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.get_group(group_id)
      end
    end
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

    tz = Time::Location.load(timezone) if timezone
    event.event_start = timezone ? Time.unix(event_start).in tz.not_nil! : Time.unix(event_start)
    event.event_end   = timezone ? Time.unix(event_end).in tz.not_nil!   : Time.unix(event_end) if event_end
    
    event.all_day = true unless event_end

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
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter }
  end
end
