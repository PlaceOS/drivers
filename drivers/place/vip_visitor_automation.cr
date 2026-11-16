require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "placeos-models/placeos-models/base/jwt"
require "jwt"
require "uuid"
require "digest/sha256"
require "./vip_visitor_planner"

# One instance per building. Planner is provided by Calendar_1.
class Place::VIPVisitorAutomation < PlaceOS::Driver
  include Place::VIPVisitorPlanner
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
    confirmation_field:       "vip_confirmed",
    confirmation_url:         "",
    domain_uri:               "",
    jwt_private_key:          PlaceOS::Model::JWTBase.private_key,
    handler_emails:           [] of String,
    notification_emails:      [] of String,
    notify_arrival_departure: false,
    location:                 "",
    google_maps_url:          "",
    parking_details:          "",
    valet_details:            "",
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

  # Also provides an operator retry after a downstream failure.
  @[Security(Level::Administrator)]
  def process_booking(booking_id : Int64, action : String = "changed")
    @lock.synchronize do
      booking = staff_api.get_booking(booking_id).get
      return false unless booking["booking_type"]? == "vip-visitor"
      building = setting(String, :building_id).strip
      raise "building_id must be configured" if building.empty?
      return false unless booking["zones"]?.try(&.as_a.includes?(JSON::Any.new(building)))
      ext = booking["extension_data"]?.try(&.as_h) || {} of String => JSON::Any
      return false if booking["parent_id"]?.try { |id| !id.raw.nil? && !id.to_s.empty? }
      return false if ext["parent_id"]?.try { |id| !id.raw.nil? && !id.to_s.empty? }
      return false if booking["deleted"]? == true || booking["cancelled"]? == true || booking["rejected"]? == true || action.in?("cancelled", "deleted", "rejected")
      state = @workflows[booking_id.to_s] ||= {} of String => JSON::Any
      confirmed = ext[setting?(String, :confirmation_field) || "vip_confirmed"]? == true
      signature = Digest::SHA256.hexdigest({
        booking["booking_start"]?, booking["booking_end"]?, booking["title"]?, booking["asset_id"]?,
        ext["vip_assistant_email"]?, ext["vip_assistant_name"]?,
      }.to_json)
      unless confirmed || state["invitation_signature"]? == signature
        send_invitation(booking, ext)
        state["invited"] = JSON::Any.new(true)
        state["invitation_signature"] = JSON::Any.new(signature)
        checkpoint
      end
      if confirmed
        unless state["confirmation_sent"]? == true
          recipients = setting(Array(String), :handler_emails).reject(&.strip.empty?)
          raise "handler_emails must be configured" if recipients.empty?
          send_notice(recipients, "confirmed", booking, ext)
          state["confirmation_sent"] = JSON::Any.new(true)
          checkpoint
        end
        provision_plan(booking, state) { checkpoint }
      end
      if setting?(Bool, :notify_arrival_departure) && action.in?("arrived", "departed") && state[action]? != true
        recipients = setting(Array(String), :notification_emails).reject(&.strip.empty?)
        unless recipients.empty?
          send_notice(recipients, action, booking, ext)
          state[action] = JSON::Any.new(true)
          checkpoint
        end
      end
      self[:last_booking_id] = booking_id
      self[:last_error] = nil
      true
    end
  end

  def template_fields : Array(TemplateFields)
    fields = %w(booking_id booking_title booking_user_name booking_user_email booking_booking_start booking_booking_end event_date event_time event_end_time location google_maps_url parking_details valet_details submitted_details confirmation_url visitor_email qr_code vip_title vip_full_name vip_mobile_number vip_assistant_name vip_assistant_email vip_assistant_mobile_number protocol_officer_name protocol_officer_mobile_number vehicle_plate_number vehicle_plate_type welcome_beverage welcome_beverage_notes).map do |name|
      {name: name, description: name.gsub('_', ' ')}
    end
    %w(invitation confirmed arrived departed).map do |name|
      TemplateFields.new(trigger: {"vip_visitor", name}, name: "VIP visitor #{name}", description: "VIP visitor #{name}", fields: fields)
    end
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
    %w(location google_maps_url parking_details valet_details).each { |key| args[key] = setting?(String, key) || "" }
    args
  end

  private def send_notice(to, template, booking, ext)
    result = mailer.send_template(to, {"vip_visitor", template}, template_args(booking, ext)).get
    raise "VIP #{template} email was not sent; check template configuration" if result.raw.nil? || result == false
  end

  private def send_invitation(booking, ext)
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
end
