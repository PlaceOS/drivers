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
    @client : ::PlaceCalendar::Client? = nil
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

  def on_unload
    @in_flight.close
    @channel.close
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
    @rate_limit = setting?(Int32, :rate_limit) || 10
    @wait_time = 1.second / @rate_limit

    @mailer_from = setting?(String, :mailer_from).presence || @service_account
    @templates = setting?(Templates, :email_templates) || Templates.new

    @in_flight.close
    @channel.close

    # Work around crystal limitation of splatting a union
    @client = begin
      config = setting(GoogleParams, :calendar_config)
      cli = ::PlaceCalendar::Client.new(**config)

      # only google uses the rate limiter
      @channel = Channel(Nil).new(9)
      @in_flight = Channel(Nil).new(10)
      spawn { rate_limiter }
      cli
    rescue
      config = setting(OfficeParams, :calendar_config)
      ::PlaceCalendar::Client.new(**config)
    end
  end

  protected def client(&)
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
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil,
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

  class ::PlaceCalendar::Member
    property next_page : String? = nil
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_members(
    group_id : String,
    next_page : String? = nil,
  )
    logger.debug { "listing members of group: #{group_id}" }

    if group_id.includes?('@')
      client do |_client|
        if _client.client_id == :office365
          logger.warn { "inefficient group members request. Recommended obtaining group.id versus using email" }
        end
      end
    end
    members = client &.get_members(group_id, next_link: next_page)

    if member = members.first?
      member.next_page = member.next_link
    end
    members
  end

  class ::PlaceCalendar::User
    property next_page : String? = nil
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_users(
    query : String? = nil,
    limit : Int32? = nil,
    filter : String? = nil,
    next_page : String? = nil,
  )
    logger.debug { "listing user details, query #{query || filter}, limit #{limit} (next: #{!!next_page})" }
    users = client &.list_users(query, limit, filter: filter, next_link: next_page)
    # next link is not returned to reduce payload size and used
    # in the staff API for setting a header
    if user = users.first?
      user.next_page = user.next_link
    end
    users
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
  def list_groups(
    query : String? = nil,
    filter : String? = nil,
  )
    logger.debug { "listing groups, filtering by #{filter || query}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        _client.calendar.as(PlaceCalendar::Office365).client.list_groups(query, filter: filter).value.map(&.to_place_group)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def get_group(group_id : String)
    logger.debug { "getting group #{group_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        if group_id.includes?('@')
          group = office_client.list_groups(filter: "mail eq '#{group_id}'").value.first?
          return group.to_place_group if group
        end
        office_client.get_group(group_id).to_place_group
      end
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_events(calendar_id : String, period_start : Int64, period_end : Int64, time_zone : String? = nil, user_id : String? = nil, include_cancelled : Bool = false, ical_uid : String? = nil)
    location = time_zone ? Time::Location.load(time_zone) : Time::Location.local
    period_start = Time.unix(period_start).in location
    period_end = Time.unix(period_end).in location
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "listing events for #{calendar_id}" }

    _client = @client.not_nil!
    events = if _client.client_id == :google
               _client.calendar.as(PlaceCalendar::Google).list_events(user_id, calendar_id,
                 period_start: period_start,
                 period_end: period_end,
                 showDeleted: include_cancelled,
                 ical_uid: ical_uid,
                 # https://cloud.google.com/apis/docs/system-parameters (avoid hitting request quotas in common driver usage)
                 quotaUser: calendar_id[0..39]
               )
             else
               _client.list_events(user_id, calendar_id,
                 period_start: period_start,
                 period_end: period_end,
                 showDeleted: include_cancelled,
                 ical_uid: ical_uid
               )
             end
    # FFS MS doesn't always filter for icaluid correctly
    events = events.select { |e| e.ical_uid == ical_uid } if ical_uid
    events
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_event(calendar_id : String, event_id : String, user_id : String? = nil)
    logger.debug { "fetching event #{event_id} on #{calendar_id}" }
    user_id = user_id || @service_account.presence || calendar_id
    client &.get_event(user_id, id: event_id, calendar_id: calendar_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "declining event #{event_id} on #{calendar_id}" }

    client &.decline_event(user_id, event_id, calendar_id: calendar_id, notify: notify, comment: comment)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "deleting event #{event_id} on #{calendar_id}" }

    client &.delete_event(user_id, event_id, calendar_id: calendar_id, notify: notify)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    user_id = user_id || @service_account.presence || calendar_id

    logger.debug { "accepting event #{event_id} on #{calendar_id}" }

    client &.accept_event(user_id, event_id, calendar_id: calendar_id, notify: notify, comment: comment)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def create_event(
    title : String,
    event_start : Int64,
    event_end : Int64? = nil,
    description : String = "",
    attendees : Array(::PlaceCalendar::Event::Attendee) = [] of ::PlaceCalendar::Event::Attendee,
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
  )
    user_id = (user_id || @service_account.presence || calendar_id).not_nil!
    calendar_id = calendar_id || user_id

    logger.debug { "creating event on #{calendar_id}" }

    event = ::PlaceCalendar::Event.new(
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

  @[PlaceOS::Driver::Security(Level::Support)]
  def update_event(event : ::PlaceCalendar::Event, user_id : String? = nil, calendar_id : String? = nil)
    user_id = (user_id || @service_account.presence || calendar_id).not_nil!
    calendar_id = calendar_id || user_id

    logger.debug { "updating event #{event.id} on #{event.host}" }

    client &.update_event(user_id: user_id, event: event, calendar_id: calendar_id)
  end

  # returns: google or office365
  def calendar_service_name
    @client.not_nil!.client_id
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def create_notifier(resource : String, notification_url : String, expiration_time : Int64, client_secret : String? = nil, lifecycle_notification_url : String? = nil) : ::PlaceCalendar::Subscription
    expires = Time.unix expiration_time
    client &.create_notifier(resource, notification_url, expires, client_secret, lifecycle_notification_url: lifecycle_notification_url)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def renew_notifier(subscription : ::PlaceCalendar::Subscription, new_expiration_time : Int64) : ::PlaceCalendar::Subscription
    expires = Time.unix new_expiration_time
    client &.renew_notifier(subscription, expires)
  end

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def reauthorize_notifier(subscription : ::PlaceCalendar::Subscription, new_expiration_time : Int64? = nil) : ::PlaceCalendar::Subscription
    expires = new_expiration_time ? Time.unix(new_expiration_time) : nil
    client &.reauthorize_notifier(subscription, expires)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def delete_notifier(subscription : ::PlaceCalendar::Subscription) : Nil
    client &.delete_notifier(subscription)
  end

  # =====================================================
  # Microsoft Graph API - Intune Device Management
  # =====================================================

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_managed_devices(filter_device_name : String? = nil)
    logger.debug { "listing managed devices, filter: #{filter_device_name}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        query_params = filter_device_name ? URI::Params{"filter" => "deviceName eq #{filter_device_name}"} : nil
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/deviceManagement/managedDevices",
            query: query_params
          )
        )
        JSON.parse(response.body).as_h["value"]
      end
    end
  end

  # NOTE:: GraphAPI Only!
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_users_managed_devices(user_id : String)
    logger.debug { "listing managed devices for user: #{user_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/users/#{user_id}/managedDevices"
          )
        )
        JSON.parse(response.body).as_h["value"]
      end
    end
  end

  # =====================================================
  # Microsoft Graph API - Planner
  # =====================================================

  # NOTE:: GraphAPI Only!
  # List plans for a group
  # https://learn.microsoft.com/en-us/graph/api/plannergroup-list-plans
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_plans(group_id : String)
    logger.debug { "listing plans for group: #{group_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/groups/#{group_id}/planner/plans"
          )
        )
        JSON.parse(response.body).as_h["value"]
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # Get a plan by ID
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-get
  @[PlaceOS::Driver::Security(Level::Support)]
  def get_plan(plan_id : String)
    logger.debug { "getting plan: #{plan_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/planner/plans/#{plan_id}"
          )
        )
        JSON.parse(response.body)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # Create a new plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-plans
  @[PlaceOS::Driver::Security(Level::Support)]
  def create_plan(group_id : String, title : String)
    logger.debug { "creating plan '#{title}' for group: #{group_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        body = {
          container: {
            url: "https://graph.microsoft.com/v1.0/groups/#{group_id}",
          },
          title: title,
        }.to_json
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "POST",
            path: "/v1.0/planner/plans",
            data: body
          )
        )
        JSON.parse(response.body)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # List buckets for a plan
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-list-buckets
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_buckets(plan_id : String)
    logger.debug { "listing buckets for plan: #{plan_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/planner/plans/#{plan_id}/buckets"
          )
        )
        JSON.parse(response.body).as_h["value"]
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # Create a bucket in a plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-buckets
  @[PlaceOS::Driver::Security(Level::Support)]
  def create_bucket(plan_id : String, name : String, order_hint : String? = nil)
    logger.debug { "creating bucket '#{name}' in plan: #{plan_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        body = {
          name:      name,
          planId:    plan_id,
          orderHint: order_hint || " !",
        }.to_json
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "POST",
            path: "/v1.0/planner/buckets",
            data: body
          )
        )
        JSON.parse(response.body)
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # List tasks for a plan
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-list-tasks
  @[PlaceOS::Driver::Security(Level::Support)]
  def list_tasks(plan_id : String)
    logger.debug { "listing tasks for plan: #{plan_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "GET",
            path: "/v1.0/planner/plans/#{plan_id}/tasks"
          )
        )
        JSON.parse(response.body).as_h["value"]
      end
    end
  end

  # NOTE:: GraphAPI Only!
  # Create a task in a plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-tasks
  # assigned_to_user_ids: array of user IDs to assign the task to
  # priority: 0-10 (0=highest, 10=lowest). 1=urgent, 3=important, 5=medium, 9=low
  @[PlaceOS::Driver::Security(Level::Support)]
  def create_task(
    plan_id : String,
    title : String,
    bucket_id : String? = nil,
    assigned_to_user_ids : Array(String)? = nil,
    due_date_time : String? = nil,
    start_date_time : String? = nil,
    percent_complete : Int32? = nil,
    priority : Int32? = nil,
    order_hint : String? = nil,
  )
    logger.debug { "creating task '#{title}' in plan: #{plan_id}, note: graphAPI only" }
    client do |_client|
      if _client.client_id == :office365
        office_client = _client.calendar.as(PlaceCalendar::Office365).client
        body = JSON.build do |json|
          json.object do
            json.field "planId", plan_id
            json.field "title", title
            json.field "bucketId", bucket_id if bucket_id
            json.field "dueDateTime", due_date_time if due_date_time
            json.field "startDateTime", start_date_time if start_date_time
            json.field "percentComplete", percent_complete if percent_complete
            json.field "priority", priority if priority
            json.field "orderHint", order_hint if order_hint

            if assigned_to_user_ids && !assigned_to_user_ids.empty?
              json.field "assignments" do
                json.object do
                  assigned_to_user_ids.each do |user_id|
                    json.field user_id do
                      json.object do
                        json.field "@odata.type", "#microsoft.graph.plannerAssignment"
                        json.field "orderHint", " !"
                      end
                    end
                  end
                end
              end
            end
          end
        end

        response = office_client.graph_request(
          office_client.graph_http_request(
            request_method: "POST",
            path: "/v1.0/planner/tasks",
            data: body
          )
        )
        JSON.parse(response.body)
      end
    end
  end

  protected def rate_limiter
    in_flight = @in_flight
    channel = @channel
    begin
      loop do
        break if channel.closed? || in_flight.closed?
        begin
          # ensure there is an available slot before allowing more requests
          in_flight.send(nil)
          in_flight.receive

          # allow more requests through
          channel.send(nil)
        rescue error
          logger.error(exception: error) { "issue with rate limiter" }
        ensure
          sleep @wait_time
        end
      end
    rescue
      # Possible error with logging exception, restart rate limiter silently
      spawn { rate_limiter } unless terminated? || channel.closed? || in_flight.closed?
    end
  end
end
