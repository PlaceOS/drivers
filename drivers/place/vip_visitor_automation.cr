require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "placeos-models/placeos-models/base/jwt"
require "jwt"
require "json"
require "uuid"
require "digest/sha256"

# One instance per building. Planner is provided by Calendar_1.
class Place::VIPVisitorAutomation < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "VIP Visitor Automation"
  generic_name :VIPVisitorAutomation
  description "Standalone VIP invitations, confirmation emails and Calendar Planner provisioning"

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1
  accessor mailer : Mailer_1

  default_settings({
    building_id:              "",
    planner_group_id:         "",
    timezone:                 "Asia/Dubai",
    confirmation_url:         "",
    domain_uri:               "",
    jwt_private_key:          PlaceOS::Model::JWTBase.private_key,
    handler_emails:           [] of String,
    planner_task_assignments: {} of String => Array(String),
  })

  @lock = Mutex.new
  @workflows = {} of String => Hash(String, JSON::Any)

  def on_load
    @workflows = setting?(Hash(String, Hash(String, JSON::Any)), :workflow_state) || @workflows
    monitor("staff/booking/changed") { |_, payload| booking_event(payload) }
    monitor("staff/guest/attending") { |_, payload| guest_event(payload) }
    monitor("staff/guest/checkin") { |_, payload| guest_event(payload) }
  end

  protected def booking_event(payload : String)
    event = JSON.parse(payload)
    action = event["action"]?.try(&.as_s) || "changed"
    if action == "checked_in"
      action = event["checked_in"]? == true ? "arrived" : "departed"
    end
    process_booking(event["id"].as_i64, action)
  rescue error
    record_error(error)
  end

  protected def guest_event(payload : String)
    event = JSON.parse(payload)
    return unless id = event["booking_id"]?
    action = event["action"]?.try(&.as_s) || "changed"
    action = event["checkin"]? == false ? "departed" : "arrived" if action == "checkin"
    process_booking(id.as_i64, action)
  rescue error
    record_error(error)
  end

  # Runs the applicable stages, or resumes after a downstream failure.
  @[Security(Level::Administrator)]
  def process_booking(booking_id : Int64, action : String = "changed")
    @lock.synchronize do
      booking = fetch_vip_booking(booking_id)
      return false unless booking
      return false if action.in?("cancelled", "deleted", "rejected")
      state = workflow(booking_id)
      if confirmed?(booking)
        send_confirmation_for(booking, state)
        provision_plan_for(booking, state) { checkpoint }
      else
        send_invitation_for(booking, state)
      end
      send_notification_for(booking, state, action) if action.in?("arrived", "departed")
      self[:last_booking_id] = booking_id
      self[:last_error] = nil
      true
    end
  rescue error
    record_error(error)
    raise error
  end

  # Look up numeric IDs for Backoffice testing, using an explicit time window.
  @[Security(Level::Administrator)]
  def list_bookings(period_start : Int64, period_end : Int64)
    raise "period_end must be after period_start" unless period_end > period_start
    bookings = staff_api.query_bookings(type: "vip-visitor", period_start: period_start,
      period_end: period_end, zones: [building_id]).get
    bookings.as_a.select { |booking| eligible_booking?(booking) }
  end

  @[Security(Level::Administrator)]
  def get_booking(booking_id : Int64)
    require_booking(booking_id)
  end

  @[Security(Level::Administrator)]
  def workflow_status(booking_id : Int64)
    @lock.synchronize { workflow_snapshot(booking_id) }
  end

  # Read-only: no JWT, email, booking update or Planner resource is created.
  @[Security(Level::Administrator)]
  def preview_booking(booking_id : Int64)
    @lock.synchronize do
      booking = require_booking(booking_id)
      state = @workflows[booking_id.to_s]? || {} of String => JSON::Any
      {
        booking_id: booking_id, confirmed: confirmed?(booking),
        planner_group_id: planner_group_id(booking, state),
        tasks: vip_planner_tasks(booking), template_args: template_args(booking, extension_data(booking)),
        workflow_state: workflow_snapshot(booking_id),
      }
    end
  end

  @[Security(Level::Administrator)]
  def send_invitation(booking_id : Int64, force : Bool = false)
    with_booking(booking_id) do |booking, state|
      raise "booking is already confirmed" if confirmed?(booking)
      send_invitation_for(booking, state, force)
    end
  end

  @[Security(Level::Administrator)]
  def send_confirmation(booking_id : Int64)
    with_booking(booking_id) do |booking, state|
      require_confirmation(booking)
      send_confirmation_for(booking, state)
    end
  end

  @[Security(Level::Administrator)]
  def provision_plan(booking_id : Int64)
    with_booking(booking_id) do |booking, state|
      require_confirmation(booking)
      provision_plan_for(booking, state) { checkpoint }
      state["plan_id"]
    end
  end

  @[Security(Level::Administrator)]
  def send_arrival_notification(booking_id : Int64)
    with_booking(booking_id) { |booking, state| send_notification_for(booking, state, "arrived") }
  end

  @[Security(Level::Administrator)]
  def send_departure_notification(booking_id : Int64)
    with_booking(booking_id) { |booking, state| send_notification_for(booking, state, "departed") }
  end

  # Matches the AECB enrolment form's field names. This is an authenticated
  # operator entry point, not an endpoint accessible with the guest JWT.
  @[Security(Level::Administrator)]
  def submit_confirmation(
    booking_id : Int64,
    vip_title : String,
    vip_full_name : String,
    vip_contact_number : String,
    assistant_name : String,
    assistant_contact_number : String,
    protocol_officer_name : String,
    protocol_officer_contact_number : String,
    vehicle_plate_number : String,
    vehicle_plate_type : String,
    beverage_preference : String,
    beverage_notes : String = "",
  )
    raise "vip_full_name is required" if vip_full_name.strip.empty?
    beverage = beverage_preference.strip.downcase
    raise "beverage_preference must be none, standard or custom" unless beverage.in?("none", "standard", "custom")
    @lock.synchronize do
      require_booking(booking_id)
      # Merge just the form fields, preserving internal options and destination.
      fields = JSON.parse({
        vip_title: vip_title, vip_full_name: vip_full_name, vip_contact_number: vip_contact_number,
        assistant_name: assistant_name, assistant_contact_number: assistant_contact_number,
        protocol_officer_name: protocol_officer_name, protocol_officer_contact_number: protocol_officer_contact_number,
        vehicle_plate_number: vehicle_plate_number, vehicle_plate_type: vehicle_plate_type,
        beverage_preference: beverage, beverage_notes: beverage == "custom" ? beverage_notes : "", vip_confirmed: true,
      }.to_json).as_h
      # Invoke the workflow directly after saving; do not also publish an event.
      staff_api.booking_extension_data(booking_id, fields, signal_changes: false).get
    end
    process_booking(booking_id)
  rescue error
    record_error(error)
    raise error
  end

  TEMPLATE_FIELD_NAMES = %w(booking_id booking_title booking_user_name booking_user_email booking_booking_start booking_booking_end event_date event_time event_end_time building_name level_name submitted_details confirmation_url visitor_email qr_code vip_title vip_full_name vip_contact_number assistant_name assistant_contact_number protocol_officer_name protocol_officer_contact_number vehicle_plate_number vehicle_plate_type beverage_preference beverage_notes vip_mobile_number vip_assistant_name vip_assistant_email vip_assistant_mobile_number protocol_officer_mobile_number welcome_beverage welcome_beverage_notes)

  def template_fields : Array(TemplateFields)
    fields = TEMPLATE_FIELD_NAMES.map { |name| {name: name, description: name.gsub('_', ' ')} }
    %w(invitation confirmed arrived departed).map do |name|
      TemplateFields.new(trigger: {"vip_visitor", name}, name: "VIP visitor #{name}", description: "VIP visitor #{name}", fields: fields)
    end
  end

  private def building_id : String
    id = setting(String, :building_id).strip
    raise "building_id must be configured" if id.empty?
    id
  end

  private def extension_data(booking : JSON::Any) : Hash(String, JSON::Any)
    booking["extension_data"]?.try(&.as_h) || {} of String => JSON::Any
  end

  private def confirmed?(booking : JSON::Any) : Bool
    extension_data(booking)["vip_confirmed"]? == true
  end

  private def require_confirmation(booking : JSON::Any)
    raise "booking must be confirmed before this stage" unless confirmed?(booking)
  end

  private def eligible_booking?(booking : JSON::Any) : Bool
    return false unless booking["booking_type"]? == "vip-visitor"
    return false unless booking["zones"]?.try(&.as_a.includes?(JSON::Any.new(building_id)))
    return false if booking["parent_id"]?.try { |id| !id.raw.nil? && !id.to_s.empty? }
    return false if extension_data(booking)["parent_id"]?.try { |id| !id.raw.nil? && !id.to_s.empty? }
    !%w(deleted cancelled rejected).any? { |key| booking[key]? == true }
  end

  private def fetch_vip_booking(booking_id : Int64) : JSON::Any?
    booking = staff_api.get_booking(booking_id).get
    eligible_booking?(booking) ? booking : nil
  end

  private def require_booking(booking_id : Int64) : JSON::Any
    fetch_vip_booking(booking_id) || raise "booking must be an active standalone VIP booking in the configured building"
  end

  private def workflow(booking_id : Int64) : Hash(String, JSON::Any)
    @workflows[booking_id.to_s] ||= {} of String => JSON::Any
  end

  private def workflow_snapshot(booking_id : Int64) : JSON::Any
    JSON.parse((@workflows[booking_id.to_s]? || {} of String => JSON::Any).to_json)
  end

  private def with_booking(booking_id : Int64, &)
    @lock.synchronize do
      booking = require_booking(booking_id)
      result = yield booking, workflow(booking_id)
      self[:last_booking_id] = booking_id
      self[:last_error] = nil
      result
    end
  rescue error
    record_error(error)
    raise error
  end

  private def send_invitation_for(booking : JSON::Any, state : Hash(String, JSON::Any), force : Bool = false) : Bool
    ext = extension_data(booking)
    signature = Digest::SHA256.hexdigest({
      booking["booking_start"]?, booking["booking_end"]?, booking["title"]?, booking["asset_id"]?,
      ext["vip_assistant_email"]?, ext["vip_assistant_name"]?,
    }.to_json)
    return false if !force && state["invitation_signature"]? == signature
    send_invitation_email(booking, ext)
    state["invited"] = JSON::Any.new(true)
    state["invitation_signature"] = JSON::Any.new(signature)
    checkpoint
    true
  end

  private def send_confirmation_for(booking : JSON::Any, state : Hash(String, JSON::Any)) : Bool
    return false if state["confirmation_sent"]? == true
    recipients = setting(Array(String), :handler_emails).reject(&.strip.empty?)
    raise "handler_emails must be configured" if recipients.empty?
    send_notice(recipients, "confirmed", booking, extension_data(booking))
    state["confirmation_sent"] = JSON::Any.new(true)
    checkpoint
    true
  end

  private def template_zone_ids : Array(String)
    # Match Template Mailer's default send_template lookup. TemplateItems in
    # supported driver shards accepts scalar values, not zone-ID arrays.
    [mailer.org_zone_id.get.as_s, mailer.building_zone_id.get.as_s]
  end

  private def send_notification_for(booking : JSON::Any, state : Hash(String, JSON::Any), action : String) : Bool
    return false if state[action]? == true
    # Without a configured metadata template, do not fall through to Mailer_2.
    template = mailer.find_template?("vip_visitor.#{action}", template_zone_ids).get
    return false if template.raw.nil?
    host = booking["user_email"]?.try(&.as_s?).presence
    raise "booking user_email is required for notifications" unless host
    send_notice([host], action, booking, extension_data(booking))
    state[action] = JSON::Any.new(true)
    checkpoint
    true
  end

  private def checkpoint
    define_setting(:workflow_state, @workflows)
  end

  private def record_error(error)
    # Do not log payloads, guest JWTs or submitted personal details.
    self[:last_error] = error.message
    logger.warn { "VIP workflow failed: #{error.message}" }
  end

  private def template_args(booking, ext)
    args = Interface::Mailer::TemplateItems.new
    TEMPLATE_FIELD_NAMES.each { |name| args[name] = nil }
    ext.each { |key, value| args[key] = value.raw.is_a?(String) ? value.as_s : value.to_json }
    %w(id title user_name user_email booking_start booking_end).each do |key|
      args["booking_#{key}"] = booking[key]?.try(&.to_s)
    end
    location = Time::Location.load(setting?(String, :timezone) || "Asia/Dubai")
    start = Time.unix(booking["booking_start"].as_i64).in(location)
    args["event_date"] = start.to_s("%A, %-d %B %Y")
    args["event_time"] = start.to_s("%H:%M %Z")
    args["event_end_time"] = Time.unix(booking["booking_end"].as_i64).in(location).to_s("%H:%M %Z")
    args["submitted_details"] = ext.to_json
    # Provide the form's current values under both UI and document field names.
    {
      "vip_mobile_number"              => "vip_contact_number",
      "vip_assistant_name"             => "assistant_name",
      "vip_assistant_mobile_number"    => "assistant_contact_number",
      "protocol_officer_mobile_number" => "protocol_officer_contact_number",
      "welcome_beverage"               => "beverage_preference",
      "welcome_beverage_notes"         => "beverage_notes",
    }.each do |document_key, form_key|
      args[document_key] = args[form_key] if ext.has_key?(form_key)
    end
    building = staff_api.zone(building_id).get
    args["building_name"] = zone_display_name(building)
    args["level_name"] = ""
    booking["zones"].as_a.each do |id|
      next if id.as_s == building_id
      zone = staff_api.zone(id.as_s).get
      if zone["tags"]?.try(&.as_a.includes?(JSON::Any.new("level")))
        args["level_name"] = zone_display_name(zone)
        break
      end
    end
    args
  end

  private def zone_display_name(zone : JSON::Any) : String
    zone["display_name"]?.try(&.as_s?).presence || zone["name"]?.try(&.as_s?) || ""
  end

  private def send_notice(to, template, booking, ext)
    result = mailer.send_template(to, {"vip_visitor", template}, template_args(booking, ext)).get
    raise "VIP #{template} email was not sent; check template configuration" if result.raw.nil? || result == false
  end

  private def send_invitation_email(booking, ext)
    assistant = ext["vip_assistant_email"]?.try(&.as_s).try(&.strip)
    raise "vip_assistant_email is required" unless assistant && !assistant.empty?
    url = URI.parse(setting(String, :confirmation_url))
    raise "confirmation_url must be an HTTPS URL" unless url.scheme == "https" && url.host
    visitor_email = booking["asset_id"].as_s
    id = booking["id"].to_s
    building = setting(String, :building_id)
    authority = URI.parse(setting(String, :domain_uri))
    raise "domain_uri must be an HTTPS authority URL" unless authority.scheme == "https" && authority.host
    now = Time.utc.to_unix
    expires = booking["booking_end"].as_i64
    raise "cannot invite an expired VIP booking" if expires <= now
    # Restricted guest token. The confirmation endpoint must authorize this
    # booking explicitly; never give external assistants public/write scope.
    token = JWT.encode({
      iss: "POS", iat: now, exp: expires, jti: UUID.random.to_s,
      aud: authority.host,
      scope: ["guest", "metadata"], sub: visitor_email,
      u: {n: ext["vip_assistant_name"]?.try(&.as_s) || assistant, e: visitor_email, p: 0, b: id, r: [id, building]},
    }, setting?(String, :jwt_private_key) || PlaceOS::Model::JWTBase.private_key, JWT::Algorithm::RS256)
    fragment = url.fragment || "/"
    path, _, query = fragment.partition('?')
    params = URI::Params.parse(query)
    params["uid"] = token
    url.fragment = "#{path}?#{params}"
    args = template_args(booking, ext)
    args["confirmation_url"] = url.to_s
    args["visitor_email"] = visitor_email
    args["qr_code"] = "cid:vip-visitor-qr"
    host = booking["user_email"]?.try(&.as_s) || ""
    png = mailer.generate_png_qrcode(text: "VISIT:#{visitor_email},#{visitor_email},#{id},#{host}", size: 256).get.as_s
    attachments = [{file_name: "vip-visitor.png", content: png, content_id: "vip-visitor-qr"}]
    result = mailer.send_template(assistant, {"vip_visitor", "invitation"}, args, resource_attachments: attachments).get
    raise "VIP invitation was not sent; check template configuration" if result.raw.nil? || result == false
  end

  # Planner orchestration uses the existing Calendar_1 module.
  private def provision_plan_for(booking : JSON::Any, state : Hash(String, JSON::Any), &checkpoint : ->)
    return if state["planner_complete"]?.try(&.as_bool?) == true

    group_id = planner_group_id(booking, state)
    raise "planner_group_id must identify an existing Microsoft 365 group" if group_id.empty?
    tasks = vip_planner_tasks(booking)
    assignments = setting?(Hash(String, Array(String)), :planner_task_assignments) || {} of String => Array(String)

    unless state["plan_id"]?
      name = booking["extension_data"]?.try(&.["vip_full_name"]?).try(&.as_s?).presence ||
             booking["title"]?.try(&.as_s?).presence || "VIP Visit"
      title = "#{name} - VIP Visit (#{booking["id"]})"
      raise "Planner plan title exceeds 255 characters" if title.size > 255
      result = calendar.create_plan(group_id, title).get
      state["plan_id"] = JSON::Any.new(vip_planner_id(result))
      # Once the plan exists, retries keep its destination even after edits.
      state["planner_group_id"] = JSON::Any.new(group_id)
      yield
    end
    plan_id = state["plan_id"].as_s

    buckets = state["bucket_ids"]?.try(&.as_h) || {} of String => JSON::Any
    state["bucket_ids"] = JSON::Any.new(buckets)
    {"To Do", "In Progress", "Done"}.each do |name|
      next if buckets[name]?
      # Place each bucket after the preceding one, using the service's hint.
      # https://learn.microsoft.com/en-us/graph/api/resources/planner-order-hint-format
      order_hint = "#{state["bucket_order_hint"]?.try(&.as_s) || ""} !"
      result = calendar.create_bucket(plan_id, name, order_hint).get
      buckets[name] = JSON::Any.new(vip_planner_id(result))
      state["bucket_order_hint"] = result["orderHint"]? || JSON::Any.new(order_hint)
      yield
    end

    task_ids = state["task_ids"]?.try(&.as_h) || {} of String => JSON::Any
    state["task_ids"] = JSON::Any.new(task_ids)
    due_at = booking["booking_start"]?.try(&.as_i64?).try { |value| Time.unix(value).to_rfc3339 }
    tasks.each do |key, title|
      next if task_ids[key]?
      result = calendar.create_task(
        plan_id: plan_id,
        title: title,
        bucket_id: buckets["To Do"].as_s,
        assigned_to_user_ids: assignments[key]?,
        due_date_time: due_at,
        percent_complete: 0,
      ).get
      task_ids[key] = JSON::Any.new(vip_planner_id(result))
      yield
    end
    state["planner_complete"] = JSON::Any.new(true)
    yield
  end

  private def planner_group_id(booking : JSON::Any, state : Hash(String, JSON::Any)) : String
    state["planner_group_id"]?.try(&.as_s?).presence ||
      extension_data(booking)["planner_group_id"]?.try(&.as_s?).try(&.strip).presence ||
      setting?(String, :planner_group_id).try(&.strip) || ""
  end

  private def vip_planner_id(result : JSON::Any) : String
    id = result["id"]?.try(&.as_s?).presence
    raise "Calendar returned no Planner resource ID" unless id
    id
  end

  private def vip_planner_tasks(booking : JSON::Any) : Hash(String, String)
    data = booking["extension_data"]?.try(&.as_h?) || {} of String => JSON::Any
    tasks = {} of String => String
    if value = vip_planner_option(data, "meet_greet")
      label = case value.downcase
              when "internal"                                          then "Internal"
              when "airport", "external - airport", "external_airport" then "Airport"
              else                                                          value
              end
      tasks["meet_greet"] = "Meet & Greet - #{label}"
    end
    {
      "tour"           => "Walkthrough/Guided Tour",
      "gift"           => "Giveaway Gift",
      "photographer"   => "Photographer",
      "welcome_screen" => "Welcome screen",
      "presentation"   => "Presentation",
    }.each do |key, title|
      selected = key == "tour" ? (data[key]? || data["walkthrough"]?) : data[key]?
      tasks[key] = title if selected.try(&.as_bool?) == true
    end
    beverage_key = data.has_key?("beverage_preference") ? "beverage_preference" : "welcome_beverage"
    if value = vip_planner_option(data, beverage_key)
      # A submitted choice replaces the booked preference, including cleared
      # notes. Do not revive organiser notes after the assistant clears them.
      notes = if data.has_key?("beverage_preference")
                value.downcase == "custom" ? data["beverage_notes"]?.try(&.as_s?).presence : nil
              else
                data["beverage_notes"]?.try(&.as_s?).presence ||
                  data["welcome_beverage_notes"]?.try(&.as_s?).presence ||
                  data["welcome_beverage_custom"]?.try(&.as_s?).presence
              end
      tasks["welcome_beverage"] = "Welcome Beverage - #{value}#{notes ? ": #{notes}" : ""}"
    end
    if restaurant = data["restaurant_reservation"]?.try(&.as_h?)
      name = restaurant["name"]?.try(&.as_s?).presence
      timestamp = restaurant["time"]?.try(&.as_i64?)
      raise "Restaurant reservation requires name and Unix time" unless name && timestamp
      zone = Time::Location.load(setting?(String, :timezone) || "Asia/Dubai")
      time = Time.unix(timestamp).in(zone).to_s("%Y-%m-%d %H:%M %z")
      address = restaurant["address"]?.try(&.as_s?).presence
      tasks["restaurant_reservation"] = "Restaurant Reservation - #{name}#{address ? ", #{address}" : ""} - #{time}"
    end
    if value = vip_planner_option(data, "driver")
      label = case value.downcase
              when "in_house", "in-house"       then "In-house"
              when "third_party", "third party" then "Third Party"
              else                                   value
              end
      tasks["driver"] = "Driver - #{label}"
    end
    tasks.each do |key, title|
      # Calendar currently has no task-details API. Keep all requested details
      # in the title and fail explicitly rather than silently dropping data.
      raise "Planner task #{key} exceeds 255 characters" if title.size > 255
    end
    tasks
  end

  private def vip_planner_option(data : Hash(String, JSON::Any), key : String) : String?
    value = data[key]?.try(&.as_s?).try(&.strip)
    return nil if value.nil? || value.empty? || value.downcase == "none"
    value
  end
end
