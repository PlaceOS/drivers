require "json-schema"
require "placeos-driver"
require "oauth2"
require "placeos"
require "link-header"
require "simple_retry"
require "place_calendar"
require "./booking_model"

# This comment is to force a recompile of the driver with updated models

class Place::StaffAPI < PlaceOS::Driver
  descriptive_name "PlaceOS Staff API"
  generic_name :StaffAPI
  description %(helpers for requesting data held in the staff API)

  # The PlaceOS API
  uri_base "https://staff"

  default_settings({
    # PlaceOS X-API-key, for simpler authentication
    api_key:                   "",
    disable_event_notify:      false,
    query_limit:               100,
    period_end_default_in_min: 60,
  })

  @place_domain : URI = URI.parse("https://staff")
  @host_header : String = ""
  @api_key : String = ""

  @authority_id : String = ""
  @event_monitoring : PlaceOS::Driver::Subscriptions::ChannelSubscription? = nil
  @notify_count : UInt64 = 0_u64
  @notify_fails : UInt64 = 0_u64

  @query_limit : Int32 = 100
  @period_end_default_in_min : Int32? = nil

  def on_update
    # x-api-key is the preferred method for API access
    @api_key = setting(String, :api_key) || ""
    @access_expires = 30.years.from_now if @api_key.presence

    @place_domain = URI.parse(config.uri.not_nil!)
    @host_header = setting?(String, :host_header) || @place_domain.host.not_nil!

    @placeos_client = nil
    @query_limit = setting?(Int32, :query_limit) || 100
    @period_end_default_in_min = setting?(Int32, :period_end_default_in_min)

    # skip if not going to work
    return unless @api_key.presence
    return if setting?(Bool, :disable_event_notify)
    schedule.clear
    schedule.every(1.hour + rand(300).seconds) { lookup_authority_id }
    schedule.in(1.second) { lookup_authority_id }
  end

  def lookup_authority_id(retry : Int32 = 0)
    response = get("/auth/authority")
    raise "unexpected response for /auth/authority: #{response.status_code}\n#{response.body}" unless response.success?

    old_id = @authority_id
    @authority_id = NamedTuple(id: String).from_json(response.body)[:id]
    monitor_event_changes unless old_id == @authority_id
    @authority_id
  rescue error
    logger.warn(exception: error) { "failed to lookup authority id" }
    sleep rand(3).seconds
    retry += 1
    return if retry == 10
    spawn { lookup_authority_id(retry) }
  end

  protected def monitor_event_changes
    if monitor = @event_monitoring
      subscriptions.unsubscribe(monitor)
      @event_monitoring = nil
    end

    @event_monitoring = monitor("#{@authority_id}/bookings/event") { |_subscription, payload| push_event_occured(payload) }
  end

  struct PushEvent
    include JSON::Serializable

    getter event_id : String
    getter change : String
    getter system_id : String
    getter event : JSON::Any?
  end

  protected def push_event_occured(payload)
    @notify_count += 1
    logger.debug { "new push event: #{payload}" }

    event = PushEvent.from_json payload

    response = post("/api/staff/v1/events/notify/#{event.change}/#{event.system_id}/#{event.event_id}",
      body: event.event.to_json,
      headers: authentication(HTTP::Headers{
        "Content-Type" => "application/json",
      })
    )
    if !response.success?
      @notify_fails += 1
      raise "unexpected response processing push event: #{response.status_code}\n#{payload}"
    end
  end

  def push_event_status
    {
      authority_id: @authority_id,
      monitoring:   !!@event_monitoring,
      events:       @notify_count,
      failures:     @notify_fails,
    }
  end

  def auth_authority
    response = get("/auth/authority")
    raise "unexpected response for /auth/authority: #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def get_system(id : String, complete : Bool = false)
    response = get("/api/engine/v2/systems/#{id}?complete=#{complete}", headers: authentication)
    raise "unexpected response for system id #{id}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing system #{id}:\n#{response.body.inspect}" }
      raise error
    end
  end

  def systems(
    q : String? = nil,
    zone_id : String? = nil,
    capacity : Int32? = nil,
    bookable : Bool? = nil,
    features : String? = nil,
    limit : Int32 = 1000,
    offset : Int32 = 0
  )
    placeos_client.systems.search(
      q: q,
      limit: limit,
      offset: offset,
      zone_id: zone_id,
      capacity: capacity,
      bookable: bookable,
      features: features
    )
  end

  record Setting, keys : Array(String), settings_string : String? do
    include JSON::Serializable
  end

  @[Security(Level::Support)]
  def system_settings(id : String, key : String)
    response = get("/api/engine/v2/systems/#{id}/settings", headers: authentication)
    raise "settings request failed for #{id}: #{response.status_code}" unless response.success?
    setting = Array(Setting).from_json(response.body).select { |sub_setting|
      sub_setting.settings_string && sub_setting.keys.includes?(key)
    }.last?
    return nil unless setting
    YAML.parse(setting.settings_string.as(String))[key]
  end

  def systems_in_building(zone_id : String, ids_only : Bool = true)
    levels = zones(parent: zone_id, tags: ["level"])
    if ids_only
      hash = {} of String => Array(String)
      levels.each { |level| hash[level.id] = systems(zone_id: level.id).map(&.id) }
    else
      hash = {} of String => Array(::PlaceOS::Client::API::Models::System)
      levels.each { |level| hash[level.id] = systems(zone_id: level.id) }
    end
    hash
  end

  # Staff details returns the information from AD
  def staff_details(email : String)
    response = get("/api/staff/v1/people/#{email}", headers: authentication)
    raise "unexpected response for staff #{email}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing staff #{email}:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # User details
  # ===================================
  def user(id : String)
    placeos_client.users.fetch(id)
  end

  @[Security(Level::Support)]
  def create_user(body_json : String)
    response = post("/api/engine/v2/users", body: body_json, headers: authentication(HTTP::Headers{
      "Content-Type" => "application/json",
    }))
    raise "failed to create user: #{response.status_code}" unless response.success?
    PlaceOS::Client::API::Models::User.from_json response.body
  end

  @[Security(Level::Support)]
  def update_user(id : String, body_json : String) : Nil
    response = patch("/api/engine/v2/users/#{id}", body: body_json, headers: authentication(HTTP::Headers{
      "Content-Type" => "application/json",
    }))

    raise "failed to update user #{id}: #{response.status_code}" unless response.success?
  end

  @[Security(Level::Support)]
  def delete_user(id : String, force_removal : Bool = false) : Nil
    response = delete("/api/engine/v2/users/#{id}?force_removal=#{force_removal}", headers: authentication)
    raise "failed to delete user #{id}: #{response.status_code}" unless response.success?
  end

  @[Security(Level::Support)]
  def revive_user(id : String) : Nil
    response = post("/api/engine/v2/users/#{id}/revive", headers: authentication)
    raise "failed to revive user #{id}: #{response.status_code}" unless response.success?
  end

  @[Security(Level::Support)]
  def resource_token
    response = post("/api/engine/v2/users/resource_token", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # NOTE:: this function requires "users" scope to be specified explicity for access
  @[Security(Level::Administrator)]
  def user_resource_token
    response = post("/api/engine/v2/users/#{invoked_by_user_id}/resource_token", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  @[Security(Level::Support)]
  def query_users(
    q : String? = nil,
    limit : Int32 = 20,
    offset : Int32 = 0,
    authority_id : String? = nil,
    include_deleted : Bool = false
  )
    placeos_client.users.search(q: q, limit: limit, offset: offset, authority_id: authority_id, include_deleted: include_deleted)
  end

  # ===================================
  # WebRTC Helper functions
  # ===================================

  @[Security(Level::Support)]
  def transfer_user(user_id : String, session_id : String, payload : JSON::Any)
    status = 200
    payload_str = payload.to_json
    SimpleRetry.try_to(
      max_attempts: 5,
      base_interval: 1.second,
      max_interval: 10.seconds,
    ) do
      response = post("/api/engine/v2/webrtc/transfer/#{user_id}/#{session_id}", headers: authentication, body: payload_str)
      # 200 == success
      # 428 == client is not connected to received the message, should be retried
      status = response.status_code
      raise "client not yet connected" unless response.success?
    end
    status
  end

  @[Security(Level::Support)]
  def kick_user(user_id : String, session_id : String, reason : String)
    response = post("/api/engine/v2/webrtc/kick/#{user_id}/#{session_id}", headers: authentication, body: {
      reason: reason,
    }.to_json)
    response.status_code
  end

  def chat_members(session_id : String) : Array(String)
    SimpleRetry.try_to(
      max_attempts: 3,
      base_interval: 1.second,
      max_interval: 5.seconds,
    ) do
      response = get("/api/engine/v2/webrtc/members/#{session_id}", headers: authentication)
      raise "webrtc service possibly unavailable" unless response.success?
      Array(String).from_json(response.not_nil!.body)
    end
  end

  # ===================================
  # Guest details
  # ===================================
  @[Security(Level::Support)]
  def guest_details(guest_id : String)
    response = get("/api/staff/v1/guests/#{guest_id}", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  @[Security(Level::Support)]
  def update_guest(id : String, body_json : String) : Nil
    response = patch("/api/staff/v1/guests/#{id}", body: body_json, headers: authentication(HTTP::Headers{
      "Content-Type" => "application/json",
    }))

    raise "failed to update guest #{id}: #{response.status_code}" unless response.success?
  end

  @[Security(Level::Support)]
  def query_guests(period_start : Int64, period_end : Int64, zones : Array(String))
    params = URI::Params.build do |form|
      form.add "period_start", period_start.to_s
      form.add "period_end", period_end.to_s
      form.add "zone_ids", zones.join(",")
    end

    response = get("/api/staff/v1/guests?#{params}", headers: authentication)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # CALENDAR EVENT ACTIONS (via staff api)
  # ===================================
  @[Security(Level::Support)]
  def query_events(
    period_start : Int64,
    period_end : Int64,
    zones : Array(String)? = nil,
    systems : Array(String)? = nil,
    capacity : Int32? = nil,
    features : String? = nil,
    bookable : Bool? = nil,
    include_cancelled : Bool? = nil
  )
    params = URI::Params.build do |form|
      form.add "period_start", period_start.to_s
      form.add "period_end", period_end.to_s
      form.add "zone_ids", zones.join(",") if zones && !zones.empty?
      form.add "system_ids", systems.join(",") if systems && !systems.empty?
      form.add "capacity", capacity.to_s if capacity
      form.add "features", features if features
      form.add "bookable", bookable.to_s if !bookable.nil?
      form.add "include_cancelled", include_cancelled.to_s if !include_cancelled.nil?
    end

    response = get("/api/staff/v1/events?#{params}", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # gets an event from either the `system_id` or `calendar` if only one is provided
  # if both are provided, it gets the event from `calendar` and the metadata from `system_id`
  # NOTE:: the use of `calendar` will typically not work from a driver unless the X-API-Key
  #        has read access to it. From a driver perspective you should probably use a
  #        dedicated Calendar driver with application access and the query_metadata function
  #        below if metadata is required: `query_metadata(system_id: "sys", event_ref: ["id", "uuid"])`
  def get_event(event_id : String, system_id : String? = nil, calendar : String? = nil)
    raise ArgumentError.new("requires system_id or calendar param") unless calendar.presence || system_id.presence
    params = URI::Params.build do |form|
      form.add "calendar", calendar.to_s if calendar.presence
      form.add "system_id", system_id.to_s if system_id.presence
    end

    response = get("/api/staff/v1/events/#{event_id}?#{params}", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # NOTE:: https://docs.google.com/document/d/1OaZljpjLVueFitmFWx8xy8BT8rA2lITyPsIvSYyNNW8/edit#
  # The service account making this request needs delegated access and hence you can only edit
  # events associated with a resource calendar
  def update_event(system_id : String, event : PlaceCalendar::Event)
    response = patch("/api/staff/v1/events/#{event.id}?system_id=#{system_id}", headers: authentication, body: event.to_json)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    PlaceCalendar::Event.from_json(response.body)
  end

  def create_event(event : PlaceCalendar::Event)
    response = post("/api/staff/v1/events", headers: authentication, body: event.to_json)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    PlaceCalendar::Event.from_json(response.body)
  end

  def delete_event(system_id : String, event_id : String)
    response = delete("/api/staff/v1/events/#{event_id}?system_id=#{system_id}", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success? || response.status_code == 404
    true
  end

  def patch_event_metadata(system_id : String, event_id : String, metadata : JSON::Any, ical_uid : String? = nil, setup_time : Int64? = nil, breakdown_time : Int64? = nil, setup_event_id : String? = nil, breakdown_event_id : String? = nil)
    params = URI::Params.build do |form|
      form.add "ical_uid", ical_uid.to_s if ical_uid.presence
      form.add "setup_time", setup_time.to_s if setup_time
      form.add "breakdown_time", breakdown_time.to_s if breakdown_time
      form.add "setup_event_id", setup_event_id.to_s if setup_event_id
      form.add "breakdown_event_id", breakdown_event_id.to_s if breakdown_event_id
    end
    response = patch("/api/staff/v1/events/#{event_id}/metadata/#{system_id}?#{params}", headers: authentication, body: metadata.to_json)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    JSON::Any.from_json(response.body)
  end

  def replace_event_metadata(system_id : String, event_id : String, metadata : JSON::Any, ical_uid : String? = nil, setup_time : Int64? = nil, breakdown_time : Int64? = nil, setup_event_id : String? = nil, breakdown_event_id : String? = nil)
    params = URI::Params.build do |form|
      form.add "ical_uid", ical_uid.to_s if ical_uid.presence
      form.add "setup_time", setup_time.to_s if setup_time
      form.add "breakdown_time", breakdown_time.to_s if breakdown_time
      form.add "setup_event_id", setup_event_id.to_s if setup_event_id
      form.add "breakdown_event_id", breakdown_event_id.to_s if breakdown_event_id
    end
    response = put("/api/staff/v1/events/#{event_id}/metadata/#{system_id}?#{params}", headers: authentication, body: metadata.to_json)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    JSON::Any.from_json(response.body)
  end

  # Search for metadata that exists on events to obtain the event information.
  # For response details see `EventMetadata__Assigner` in the OpenAPI docs
  # https://editor.swagger.io/?url=https://raw.githubusercontent.com/PlaceOS/staff-api/master/OPENAPI_DOC.yml
  def query_metadata(
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    field_name : String? = nil,
    value : String? = nil,
    system_id : String? = nil,
    event_ref : Array(String)? = nil
  )
    params = URI::Params.build do |form|
      form.add "period_start", period_start.to_s if period_start
      form.add "period_end", period_end.to_s if period_end
      form.add "field_name", field_name if field_name.presence
      form.add "value", value if value.presence
      form.add "event_ref", event_ref.join(",") if event_ref && !event_ref.empty?
    end

    response = get("/api/staff/v1/events/extension_metadata/#{system_id}?#{params}", headers: authentication)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # ZONE METADATA
  # ===================================
  def metadata(id : String, key : String? = nil)
    placeos_client.metadata.fetch(id, key)
  end

  def metadata_children(id : String, key : String? = nil)
    placeos_client.metadata.children(id, key)
  end

  @[Security(Level::Support)]
  def write_metadata(id : String, key : String, payload : JSON::Any, description : String = "")
    placeos_client.metadata.update(id, key, payload, description)
  end

  @[Security(Level::Support)]
  def merge_metadata(id : String, key : String, payload : JSON::Any, description : String = "")
    placeos_client.metadata.merge(id, key, payload, description)
  end

  # ===================================
  # ZONE INFORMATION
  # ===================================
  def zone(zone_id : String)
    placeos_client.zones.fetch zone_id
  end

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    placeos_client.zones.search(
      q: q,
      limit: limit,
      offset: offset,
      parent_id: parent,
      tags: tags
    )
  end

  # ===================================
  # BOOKINGS ACTIONS
  # ===================================
  @[Security(Level::Support)]
  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    checked_in : Bool = false,
    approved : Bool? = nil,
    title : String? = nil,
    description : String? = nil,
    time_zone : String? = nil,
    extension_data : JSON::Any? = nil,
    utm_source : String? = nil,
    limit_override : Int64? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    attendees : Array(PlaceCalendar::Event::Attendee)? = nil,
    process_state : String? = nil,
    recurrence_type : String? = nil,
    recurrence_days : Int32? = nil,
    recurrence_nth_of_month : Int32? = nil,
    recurrence_interval : Int32? = nil,
    recurrence_end : Int64? = nil
  )
    now = time_zone ? Time.local(Time::Location.load(time_zone)) : Time.local
    booking_start ||= now.at_beginning_of_day.to_unix
    booking_end ||= now.at_end_of_day.to_unix

    checked_in_at = now.to_unix if checked_in

    logger.debug { "creating a #{booking_type} booking, starting #{booking_start}, asset #{asset_id}" }

    params = URI::Params.build do |form|
      form.add "utm_source", utm_source.to_s unless utm_source.nil?
      form.add "limit_override", limit_override.to_s unless limit_override.nil?
      form.add "event_id", event_id.to_s unless event_id.nil?
      form.add "ical_uid", ical_uid.to_s unless ical_uid.nil?
    end

    response = post("/api/staff/v1/bookings?#{params}", headers: authentication, body: {
      "booking_start"           => booking_start,
      "booking_end"             => booking_end,
      "booking_type"            => booking_type,
      "asset_id"                => asset_id,
      "user_id"                 => user_id,
      "user_email"              => user_email,
      "user_name"               => user_name,
      "zones"                   => zones,
      "checked_in"              => checked_in,
      "checked_in_at"           => checked_in_at,
      "approved"                => approved,
      "title"                   => title,
      "description"             => description,
      "timezone"                => time_zone,
      "extension_data"          => extension_data || JSON.parse("{}"),
      "attendees"               => attendees,
      "process_state"           => process_state,
      "recurrence_type"         => recurrence_type,
      "recurrence_days"         => recurrence_days,
      "recurrence_nth_of_month" => recurrence_nth_of_month,
      "recurrence_interval"     => recurrence_interval,
      "recurrence_end"          => recurrence_end,
    }.compact.to_json)
    raise "issue creating #{booking_type} booking, starting #{booking_start}, asset #{asset_id}: #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def update_booking(
    booking_id : String | Int64,
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    asset_id : String? = nil,
    title : String? = nil,
    description : String? = nil,
    timezone : String? = nil,
    extension_data : JSON::Any? = nil,
    approved : Bool? = nil,
    checked_in : Bool? = nil,
    limit_override : Int64? = nil,
    instance : Int64? = nil,
    recurrence_end : Int64? = nil,
  )
    logger.debug { "updating booking #{booking_id}" }

    case checked_in
    in true
      checked_in_at = Time.utc.to_unix
    in false
      checked_out_at = Time.utc.to_unix
    in nil
    end

    params = URI::Params.build do |form|
      form.add "limit_override", limit_override.to_s unless limit_override.nil?
    end

    response = patch("/api/staff/v1/bookings/#{booking_id}?#{params}", headers: authentication, body: {
      "booking_start"  => booking_start,
      "booking_end"    => booking_end,
      "checked_in"     => checked_in,
      "checked_in_at"  => checked_in_at,
      "checked_out_at" => checked_out_at,
      "asset_id"       => asset_id,
      "title"          => title,
      "description"    => description,
      "timezone"       => timezone,
      "extension_data" => extension_data,
      "instance"       => instance,
      "recurrence_end" => recurrence_end,
    }.compact.to_json)
    raise "issue updating booking #{booking_id}: #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def reject(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    logger.debug { "rejecting booking #{booking_id}" }

    params = URI::Params.build do |form|
      form.add "instance", instance.to_s unless instance.nil?
      form.add "utm_source", utm_source.to_s unless utm_source.nil?
    end

    response = post("/api/staff/v1/bookings/#{booking_id}/reject?#{params}", headers: authentication)
    raise "issue rejecting booking #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def approve(booking_id : String | Int64, instance : Int64? = nil)
    logger.debug { "approving booking #{booking_id}" }
    inst = "/instance/#{instance}" if instance
    response = post("/api/staff/v1/bookings/#{booking_id}/approve#{inst}", headers: authentication)
    raise "issue approving booking #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    logger.debug { "updating booking #{booking_id}.#{instance} state to: #{state}" }
    inst = "&instance=#{instance}" if instance
    response = post("/api/staff/v1/bookings/#{booking_id}/update_state?state=#{state}#{inst}", headers: authentication)
    raise "issue updating booking state #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_check_in(booking_id : String | Int64, state : Bool = true, utm_source : String? = nil, instance : Int64? = nil)
    logger.debug { "checking in booking #{booking_id}.#{instance} to: #{state}" }

    params = URI::Params.build do |form|
      form.add "instance", instance.to_s unless instance.nil?
      form.add "utm_source", utm_source.to_s unless utm_source.nil?
      form.add "state", state.to_s
    end
    response = post("/api/staff/v1/bookings/#{booking_id}/check_in?#{params}", headers: authentication)
    raise "issue checking in booking #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_delete(booking_id : String | Int64, utm_source : String? = nil, instance : Int64? = nil)
    logger.debug { "deleting booking #{booking_id}" }
    params = URI::Params.build do |form|
      form.add "instance", instance.to_s unless instance.nil?
      form.add "utm_source", utm_source.to_s unless utm_source.nil?
    end
    response = delete("/api/staff/v1/bookings/#{booking_id}?#{params}", headers: authentication)
    raise "issue updating booking state #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_extension_data(booking_id : String | Int64, extension_data : Hash(String, JSON::Any), instance : Int64? = nil, signal_changes : Bool = false)
    logger.debug { "updating booking ext data #{booking_id}.#{instance} with: #{extension_data}" }

    params = URI::Params.build do |form|
      form.add "signal_changes", signal_changes.to_s
    end

    response = patch("/api/staff/v1/bookings/#{booking_id}/ext_data/#{instance}?#{params}", headers: authentication, body: extension_data.to_json)
    raise "issue updating booking #{booking_id}.#{instance}: #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  # ===================================
  # BOOKINGS QUERY
  # ===================================
  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    extension_data : JSON::Any? = nil,
    deleted : Bool? = nil,
    asset_id : String? = nil,
    limit : Int32? = nil
  )
    default_end = @period_end_default_in_min || 30

    # Assumes occuring now
    period_start ||= Time.utc.to_unix
    period_end ||= default_end.minutes.from_now.to_unix
    limit ||= @query_limit

    params = URI::Params.build do |form|
      form.add "period_start", period_start.to_s if period_start
      form.add "period_end", period_end.to_s if period_end
      form.add "type", type.to_s if type.presence

      form.add "zones", zones.join(",") unless zones.empty?
      form.add "user", user.to_s if user.presence
      form.add "email", email.to_s if email.presence
      form.add "state", state.to_s if state.presence
      form.add "created_before", created_before.to_s if created_before
      form.add "created_after", created_after.to_s if created_after
      form.add "approved", approved.to_s unless approved.nil?
      form.add "rejected", rejected.to_s unless rejected.nil?
      form.add "checked_in", checked_in.to_s unless checked_in.nil?
      form.add "deleted", deleted.to_s unless deleted.nil?
      form.add "event_id", event_id.to_s if event_id.presence
      form.add "ical_uid", ical_uid.to_s if ical_uid.presence
      form.add "include_checked_out", include_checked_out.to_s unless include_checked_out.nil?

      form.add "asset_id", asset_id.to_s unless asset_id.nil?
      form.add "limit", limit.to_s

      if extension_data
        value = extension_data.as_h.map { |k, v| "#{k}:#{v}" }.join(",")
        form.add "extension_data", "{#{value}}"
      end
    end

    logger.debug { "requesting staff/v1/bookings: #{params}" }

    # Get the existing bookings from the API to check if there is space
    bookings = [] of JSON::Any
    next_request = "/api/staff/v1/bookings?#{params}"

    loop do
      response = get(next_request, headers: authentication)
      raise "issue loading list of bookings (zones #{zones}): #{response.status_code}" unless response.success?
      links = LinkHeader.new(response)

      # Just parse it here instead of using the Bookings object
      # it will be parsed into an object on the far end
      new_bookings = JSON.parse(response.body).as_a
      bookings.concat new_bookings

      last_req = next_request
      next_request = links["next"]?
      break if next_request.nil? || new_bookings.empty? || last_req == next_request
    end

    logger.debug { "bookings count: #{bookings.size}" }

    bookings
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    logger.debug { "getting booking #{booking_id}" }
    params = "?instance=#{instance}" if instance
    response = get("/api/staff/v1/bookings/#{booking_id}#{params}", headers: authentication)
    raise "issue getting booking #{booking_id}: #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # lists asset IDs based on the parameters provided
  #
  # booking_type is required unless event_id or ical_uid is present
  def booked(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    include_booked_by : Bool? = nil,
    department : String? = nil,
    limit : Int32? = nil,
    offset : Int32? = nil,
    permission : String? = nil,
    extension_data : JSON::Any? = nil,
  )
    params = URI::Params.build do |form|
      form.add "period_start", period_start.to_s if period_start
      form.add "period_end", period_end.to_s if period_end
      form.add "type", type.to_s if type.presence

      form.add "zones", zones.join(",") unless zones.empty?
      form.add "user", user.to_s if user.presence
      form.add "email", email.to_s if email.presence
      form.add "state", state.to_s if state.presence
      form.add "created_before", created_before.to_s if created_before
      form.add "created_after", created_after.to_s if created_after
      form.add "approved", approved.to_s unless approved.nil?
      form.add "checked_in", checked_in.to_s unless checked_in.nil?
      form.add "event_id", event_id.to_s if event_id.presence
      form.add "ical_uid", ical_uid.to_s if ical_uid.presence
      form.add "include_checked_out", include_checked_out.to_s unless include_checked_out.nil?
      form.add "include_booked_by", include_booked_by.to_s unless include_booked_by.nil?
      form.add "department", department.to_s if department.presence
      form.add "limit", limit.to_s if limit
      form.add "offset", offset.to_s if offset
      form.add "permission", permission.to_s if permission.presence

      if extension_data
        value = extension_data.as_h.map { |k, v| "#{k}:#{v}" }.join(",")
        form.add "extension_data", "{#{value}}"
      end
    end

    logger.debug { "requesting staff/v1/bookings/booked: #{params}" }
    response = get("/api/staff/v1/bookings/booked?#{params}", headers: authentication)
    raise "issue getting booked assets: #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # ===================================
  # Driver debugging
  # ===================================

  def driver_introspection
    {
      protocol: PlaceOS::Driver::Stats.protocol_tracking,
      memory:   PlaceOS::Driver::Stats.memory_usage,
      queue:    @__queue__.@queue.size,
    }
  end

  # ===================================
  # SURVEYS
  # ===================================

  def get_survey_invites(survey_id : Int64? = nil, sent : Bool? = nil)
    logger.debug { "getting survey_invites (survey #{survey_id}, sent #{sent})" }
    params = URI::Params.new
    params["survey_id"] = survey_id.to_s if survey_id
    params["sent"] = sent.to_s unless sent.nil?
    response = get("/api/staff/v1/surveys/invitations", params, headers: authentication)
    raise "issue getting survey invitations (survey #{survey_id}, sent #{sent}): #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def update_survey_invite(
    token : String,
    email : String? = nil,
    sent : Bool? = nil
  )
    logger.debug { "updating survey invite #{token}" }
    response = patch("/api/staff/v1/surveys/invitations/#{token}", headers: authentication, body: {
      "email" => email,
      "sent"  => sent,
    }.compact.to_json)
    raise "issue updating survey invite #{token}: #{response.status_code}" unless response.success?
    true
  end

  # ===================================

  @[Security(Level::Support)]
  def signal(channel : String, payload : JSON::Any? = nil)
    placeos_client.root.signal(channel, payload)
  end

  # For accessing PlaceOS APIs
  protected getter placeos_client : PlaceOS::Client do
    PlaceOS::Client.new(
      @place_domain,
      host_header: @host_header,
      x_api_key: @api_key
    )
  end

  # ===================================
  # PLACEOS AUTHENTICATION:
  # ===================================
  protected def authentication(headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Headers
    headers["Accept"] = "application/json"
    headers["X-API-Key"] = @api_key.presence || "spec-test"
    headers
  end
end
