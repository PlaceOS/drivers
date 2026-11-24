require "placeos-driver/spec"
require "placeos-driver/interface/mailer"
require "base64"

class VIPStaffMock < DriverSpecs::MockDriver
  @start = (Time.utc + 1.day).to_unix
  @pending_offset = 0_i64
  @overrides = {} of Int64 => Hash(String, JSON::Any)
  @level_display_name = "Level Display"

  def set_level_display_name(value : String)
    @level_display_name = value
  end

  def zone(zone_id : String)
    case zone_id
    when "zone-aecb"
      {id: zone_id, name: "Building Internal", display_name: "Building Display", tags: ["building"]}
    when "zone-level"
      {id: zone_id, name: "Level Internal", display_name: @level_display_name, tags: ["level"], parent_id: "zone-aecb"}
    else
      raise "unexpected zone #{zone_id}"
    end
  end

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
    limit : Int32? = nil,
  )
    raise "wrong booking filter" unless type == "vip-visitor" && zones == ["zone-aecb"]
    raise "missing query window" unless period_start && period_end && period_start < period_end
    [get_booking(1)]
  end

  def booking_extension_data(booking_id : String | Int64, extension_data : Hash(String, JSON::Any), instance : Int64? = nil, signal_changes : Bool = false)
    id = booking_id.to_i64
    (@overrides[id] ||= {} of String => JSON::Any).merge!(extension_data)
    self[:last_extension_update] = extension_data
    self[:signal_changes] = signal_changes
    get_booking(id)
  end

  def postpone_pending
    @pending_offset = 3600_i64
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    id = booking_id.to_i64
    start = @start + (id == 1 ? @pending_offset : 0_i64)
    booking = JSON.parse({
      id: id, booking_type: "vip-visitor", booking_start: start,
      booking_end: start + 3600, zones: ["zone-aecb", "zone-level"], title: "VIP Guest",
      asset_id: "vip@example.net", user_email: "host@example.com",
      booked_by_email: "booker@example.com", booked_by_name: "Booker",
      extension_data: {
        vip_assistant_email: "assistant@example.net", vip_full_name: "VIP Guest",
        vip_confirmed: id != 1,
      },
    }.to_json)
    data = booking["extension_data"].as_h
    case id
    when 2
      data.merge!(JSON.parse({
        meet_greet: "External - Airport", tour: true, welcome_beverage: "Custom",
        welcome_beverage_notes: "Tea", gift: true, photographer: true,
        restaurant_reservation: {name: "Restaurant", address: "Dubai", time: @start},
        driver: "Third Party", welcome_screen: true, presentation: true,
      }.to_json).as_h)
    when 3
      booking.as_h["booking_type"] = JSON::Any.new("visitor")
    when 4
      booking.as_h["zones"] = JSON.parse(["zone-other"].to_json)
    when 5
      data["parent_id"] = JSON::Any.new("event-parent")
    when 6
      booking.as_h["cancelled"] = JSON::Any.new(true)
    when 7
      booking.as_h["deleted"] = JSON::Any.new(true)
    when 8
      data.merge!(JSON.parse({meet_greet: "None", welcome_beverage: "none", driver: "", tour: false}.to_json).as_h)
    when 9
      data["tour"] = JSON::Any.new(true)
      data["gift"] = JSON::Any.new(true)
    when 10
      data.merge!(JSON.parse({meet_greet: "internal", walkthrough: true,
                              welcome_beverage: "Standard", beverage_preference: "Custom", beverage_notes: "Coffee",
                              driver: "in_house", vip_mobile_number: "+971500000000", protocol_officer_name: "Officer"}.to_json).as_h)
    when 11
      data.merge!(JSON.parse({meet_greet: "airport", driver: "third_party",
                              welcome_beverage: "Custom", beverage_preference: "None"}.to_json).as_h)
    when 12
      booking.as_h["parent_id"] = JSON::Any.new(123_i64)
    when 13
      booking.as_h["rejected"] = JSON::Any.new(true)
    when 14
      data.merge!(JSON.parse({welcome_beverage: "Custom", welcome_beverage_custom: "Juice"}.to_json).as_h)
    end
    if overrides = @overrides[id]?
      data.merge!(overrides)
    end
    booking
  end
end

class VIPCalendarMock < DriverSpecs::MockDriver
  @plans = [] of String
  @buckets = [] of String
  @tasks = [] of String
  @failed_once = false
  @fail_next_plan = false
  @groups = [] of String

  def fail_next_plan
    @fail_next_plan = true
  end

  def on_load
    self[:plans] = @plans
    self[:buckets] = @buckets
    self[:tasks] = @tasks
    self[:groups] = @groups
  end

  def create_plan(group_id : String, title : String)
    @groups << group_id
    self[:groups] = @groups
    if @fail_next_plan
      @fail_next_plan = false
      raise "temporary plan creation failure"
    end
    @plans << title
    self[:plans] = @plans
    {id: "plan-#{@plans.size}"}
  end

  def create_bucket(plan_id : String, name : String, order_hint : String? = nil)
    @buckets << "#{plan_id}:#{name}"
    self[:buckets] = @buckets
    self[:order_hint] = order_hint
    {id: "bucket-#{@buckets.size}", orderHint: "hint-#{@buckets.size}"}
  end

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
    if plan_id == "plan-3" && title == "Giveaway Gift" && !@failed_once
      @failed_once = true
      raise "temporary Planner failure"
    end
    raise "tasks must start incomplete" unless percent_complete == 0
    raise "tasks require due time" unless due_date_time
    if title.starts_with?("Meet & Greet")
      raise "assignment was not forwarded" unless assigned_to_user_ids == ["user-greeter"]
    end
    @tasks << "#{plan_id}:#{bucket_id}:#{title}"
    self[:tasks] = @tasks
    {id: "task-#{@tasks.size}"}
  end
end

class VIPMailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer
  @recipients = [] of String
  @sent_templates = [] of String
  @missing_templates = [] of String

  def org_zone_id : String
    "zone-org"
  end

  def building_zone_id : String
    "zone-aecb"
  end

  def disable_template(template : String)
    @missing_templates << template
  end

  def enable_template(template : String)
    @missing_templates.delete(template)
  end

  def find_template?(template : String, zone_ids : Array(String)) : Hash(String, String | Int64)?
    raise "template lookup must match the mailer default context" unless zone_ids == ["zone-org", "zone-aecb"]
    return nil if @missing_templates.includes?(template)
    {"trigger" => template} of String => String | Int64
  end

  def on_load
    self[:recipients] = @recipients
    self[:templates] = @sent_templates
  end

  def generate_png_qrcode(text : String, size : Int32 = 128) : String
    "QR-#{text}"
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil,
  )
    @sent_templates << template.join(".")
    self[:templates] = @sent_templates
    @recipients.concat(to.is_a?(String) ? [to] : to)
    self[:recipients] = @recipients
    self[:last_args] = args
    self[:last_template] = template
    true
  end

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
  ) : Bool
    true
  end
end

DriverSpecs.mock_driver "Place::VIPVisitorAutomation" do
  system({StaffAPI: {VIPStaffMock}, Calendar: {VIPCalendarMock}, Mailer: {VIPMailerMock}})
  settings({
    building_id: "zone-aecb", planner_group_id: "group-aecb",
    confirmation_url: "https://example.com/vip-confirmation",
    domain_uri: "https://example.com", handler_emails: ["handler@example.com"],
    planner_task_assignments: {meet_greet: ["user-greeter"]},
  })

  exec(:process_booking, 1).get
  invitation = system(:Mailer)[:last_args]
  uri = URI.parse(invitation["confirmation_url"].as_s)
  token = URI::Params.parse(uri.fragment.not_nil!.partition('?')[2])["uid"]
  encoded = token.split('.')[1].tr("-_", "+/")
  encoded += "=" * ((4 - encoded.size % 4) % 4)
  claims = JSON.parse(Base64.decode_string(encoded))
  claims["scope"].should eq ["guest", "metadata"]
  claims["u"]["b"].should eq "1"
  claims["u"]["r"].should eq ["1", "zone-aecb"]
  claims["u"]["e"].should eq "vip@example.net"
  claims["aud"].should eq "example.com"
  system(:Mailer)[:recipients].should eq ["assistant@example.net"]
  system(:Calendar)[:plans].should eq [] of String
  exec(:process_booking, 1).get
  system(:Mailer)[:recipients].should eq ["assistant@example.net"]

  exec(:process_booking, 2).get
  system(:Calendar)[:plans].as_a.size.should eq 1
  system(:Calendar)[:buckets].should eq ["plan-1:To Do", "plan-1:In Progress", "plan-1:Done"]
  system(:Calendar)[:order_hint].should eq "hint-2 !"
  tasks = system(:Calendar)[:tasks].as_a.map(&.as_s)
  tasks.size.should eq 9
  tasks.all?(&.starts_with?("plan-1:bucket-1:")).should be_true
  tasks.any?(&.includes?("Meet & Greet - Airport")).should be_true
  tasks.any?(&.includes?("Welcome Beverage - Custom: Tea")).should be_true
  tasks.any?(&.includes?("Restaurant Reservation - Restaurant, Dubai")).should be_true
  tasks.any?(&.includes?("Driver - Third Party")).should be_true
  system(:Mailer)[:recipients].as_a.map(&.as_s).includes?("handler@example.com").should be_true
  emails = system(:Mailer)[:recipients]
  exec(:process_booking, 2).get
  system(:Calendar)[:tasks].as_a.size.should eq 9
  system(:Mailer)[:recipients].should eq emails

  (3..7).each { |id| exec(:process_booking, id).get }
  system(:Calendar)[:plans].as_a.size.should eq 1
  system(:Mailer)[:recipients].should eq emails

  exec(:process_booking, 8).get
  system(:Calendar)[:plans].as_a.size.should eq 2
  system(:Calendar)[:buckets].as_a.size.should eq 6
  system(:Calendar)[:tasks].as_a.size.should eq 9

  expect_raises(Exception) { exec(:process_booking, 9).get }
  system(:Calendar)[:tasks].as_a.size.should eq 10
  # The plan already exists, so an edited booking cannot redirect a retry.
  system(:StaffAPI).as(VIPStaffMock).booking_extension_data(9, JSON.parse({planner_group_id: "group-changed"}.to_json).as_h)
  exec(:workflow_status, 9).get["planner_group_id"].should eq "group-aecb"
  exec(:preview_booking, 9).get["planner_group_id"].should eq "group-aecb"
  plan_attempts = system(:Calendar)[:groups].as_a.size
  exec(:process_booking, 9).get
  system(:Calendar)[:groups].as_a.size.should eq plan_attempts
  system(:Calendar)[:plans].as_a.size.should eq 3
  system(:Calendar)[:buckets].as_a.size.should eq 9
  system(:Calendar)[:tasks].as_a.size.should eq 11

  exec(:process_booking, 10).get
  tasks = system(:Calendar)[:tasks].as_a.map(&.as_s)
  tasks.any?(&.ends_with?("Meet & Greet - Internal")).should be_true
  tasks.any?(&.ends_with?("Welcome Beverage - Custom: Coffee")).should be_true
  tasks.any?(&.ends_with?("Driver - In-house")).should be_true
  tasks.count(&.ends_with?("Walkthrough/Guided Tour")).should eq 3
  args = system(:Mailer)[:last_args]
  args["vip_mobile_number"].should eq "+971500000000"
  args["protocol_officer_name"].should eq "Officer"
  JSON.parse(args["submitted_details"].as_s)["beverage_notes"].should eq "Coffee"

  exec(:process_booking, 11).get
  tasks = system(:Calendar)[:tasks].as_a.map(&.as_s)
  tasks.select(&.starts_with?("plan-5:")).size.should eq 2
  exec(:process_booking, 12).get
  exec(:process_booking, 13).get
  system(:Calendar)[:plans].as_a.size.should eq 5
  exec(:process_booking, 14).get
  system(:Calendar)[:tasks].as_a.map(&.as_s).any?(&.ends_with?("Welcome Beverage - Custom: Juice")).should be_true

  # A metadata update triggers acceptance processing; the guest attending
  # signal alone must never be treated as an arrival or as confirmation.
  publish("staff/booking/changed", {id: 15, action: "metadata_changed"}.to_json)
  sleep 0.5
  system(:Calendar)[:plans].as_a.size.should eq 7
  publish("staff/guest/attending", {booking_id: 1, action: "attending"}.to_json)
  sleep 0.5
  system(:Calendar)[:plans].as_a.size.should eq 7

  settings({
    building_id: "zone-aecb", planner_group_id: "group-aecb",
    confirmation_url: "https://example.com/vip-confirmation", domain_uri: "https://example.com",
    handler_emails: ["handler@example.com"],
    planner_task_assignments: {meet_greet: ["user-greeter"]},
  })
  publish("staff/booking/changed", {id: 15, action: "checked_in", checked_in: true}.to_json)
  sleep 0.5
  publish("staff/guest/checkin", {booking_id: 15, action: "checkin", checkin: true}.to_json)
  sleep 0.5
  system(:Mailer)[:recipients].as_a.count { |email| email == "host@example.com" }.should eq 1
  publish("staff/guest/checkin", {booking_id: 15, action: "checkin", checkin: false}.to_json)
  sleep 0.5
  publish("staff/booking/changed", {id: 15, action: "checked_in", checked_in: false}.to_json)
  sleep 0.5
  system(:Mailer)[:recipients].as_a.count { |email| email == "host@example.com" }.should eq 2

  # Editing a pending visit refreshes its invitation, without accepting it.
  system(:StaffAPI).as(VIPStaffMock).postpone_pending
  exec(:process_booking, 1).get
  system(:Mailer)[:recipients].as_a.count { |email| email == "assistant@example.net" }.should eq 2
  system(:Calendar)[:plans].as_a.size.should eq 7
  exec(:process_booking, 1).get
  system(:Mailer)[:recipients].as_a.count { |email| email == "assistant@example.net" }.should eq 2

  # Read-only Backoffice inspection exposes the real booking IDs, zone display
  # names and planned tasks without sending email or provisioning resources.
  plans_before = system(:Calendar)[:plans].as_a.size
  messages_before = system(:Mailer)[:templates].as_a.size
  exec(:get_booking, 1).get["id"].should eq 1
  [3, 4, 5, 6, 7, 12, 13].each do |id|
    expect_raises(Exception) { exec(:get_booking, id).get }
  end
  start_time = Time.utc.to_unix
  exec(:list_bookings, start_time, start_time + 86400).get.as_a.map(&.["id"].as_i64).should eq [1_i64]
  expect_raises(Exception) { exec(:list_bookings, start_time + 86400, start_time).get }
  preview = exec(:preview_booking, 2).get
  preview["booking_id"].should eq 2
  preview["confirmed"].should eq true
  preview["planner_group_id"].should eq "group-aecb"
  preview["tasks"].as_h.size.should eq 9
  preview["template_args"]["building_name"].should eq "Building Display"
  preview["template_args"]["level_name"].should eq "Level Display"
  exec(:workflow_status, 2).get["planner_complete"].should eq true
  exec(:workflow_status, 99).get.as_h.should be_empty
  system(:StaffAPI).as(VIPStaffMock).set_level_display_name("")
  exec(:preview_booking, 1).get["template_args"]["level_name"].should eq "Level Internal"
  system(:StaffAPI).as(VIPStaffMock).set_level_display_name("Level Display")
  system(:Calendar)[:plans].as_a.size.should eq plans_before
  system(:Mailer)[:templates].as_a.size.should eq messages_before

  fields = exec(:template_fields).get.as_a.first["fields"].as_a.map(&.["name"].as_s)
  %w(building_name level_name vip_contact_number assistant_name assistant_contact_number protocol_officer_contact_number beverage_preference beverage_notes).each do |key|
    fields.includes?(key).should be_true
  end
  %w(location google_maps_url parking_details valet_details).each do |key|
    fields.includes?(key).should be_false
  end

  # Stage methods only perform their own stage, retain eligibility checks, and
  # cannot provision or report acceptance of an unconfirmed booking.
  exec(:send_invitation, 1).get
  system(:Mailer)[:templates].as_a.size.should eq messages_before
  exec(:send_invitation, 1, true).get
  system(:Mailer)[:templates].as_a.size.should eq messages_before + 1
  expect_raises(Exception) { exec(:send_confirmation, 1).get }
  expect_raises(Exception) { exec(:provision_plan, 1).get }
  system(:Calendar)[:plans].as_a.size.should eq plans_before
  exec(:send_confirmation, 16).get
  system(:Mailer)[:templates].as_a.last.should eq "vip_visitor.confirmed"
  system(:Calendar)[:plans].as_a.size.should eq plans_before
  messages_before = system(:Mailer)[:templates].as_a.size
  exec(:send_confirmation, 16).get
  system(:Mailer)[:templates].as_a.size.should eq messages_before
  exec(:provision_plan, 16).get
  system(:Calendar)[:plans].as_a.size.should eq plans_before + 1
  system(:Mailer)[:templates].as_a.size.should eq messages_before

  # Notifications are enabled by the template's presence. An absent template
  # neither sends nor marks the stage complete, so adding it allows a retry.
  mailer = system(:Mailer).as(VIPMailerMock)
  mailer.disable_template("vip_visitor.arrived")
  exec(:send_arrival_notification, 17).get.should eq false
  system(:Mailer)[:templates].as_a.size.should eq messages_before
  exec(:workflow_status, 17).get["arrived"]?.should_not eq true
  mailer.enable_template("vip_visitor.arrived")
  exec(:send_arrival_notification, 17).get
  system(:Mailer)[:templates].as_a.last.should eq "vip_visitor.arrived"
  system(:Mailer)[:recipients].as_a.last.should eq "host@example.com"
  exec(:send_arrival_notification, 17).get
  system(:Mailer)[:templates].as_a.size.should eq messages_before + 1
  exec(:send_departure_notification, 17).get
  system(:Mailer)[:templates].as_a.last.should eq "vip_visitor.departed"
  system(:Calendar)[:plans].as_a.size.should eq plans_before + 1

  # A booking destination overrides the module default. Failed creation leaves
  # it editable; only a successfully created plan pins its destination.
  staff = system(:StaffAPI).as(VIPStaffMock)
  staff.booking_extension_data(18, JSON.parse({planner_group_id: "group-booking"}.to_json).as_h)
  exec(:preview_booking, 18).get["planner_group_id"].should eq "group-booking"
  system(:Calendar).as(VIPCalendarMock).fail_next_plan
  expect_raises(Exception) { exec(:provision_plan, 18).get }
  exec(:workflow_status, 18).get["planner_group_id"]?.should be_nil
  exec(:workflow_status, 18).get["plan_id"]?.should be_nil
  staff.booking_extension_data(18, JSON.parse({planner_group_id: "group-changed"}.to_json).as_h)
  exec(:provision_plan, 18).get
  system(:Calendar)[:groups].as_a.last(2).should eq ["group-booking", "group-changed"]
  exec(:workflow_status, 18).get["planner_group_id"].should eq "group-changed"
  exec(:preview_booking, 18).get["planner_group_id"].should eq "group-changed"

  # Blank booking overrides fall back to the module; no destination fails
  # clearly before a plan request and does not mark the workflow complete.
  staff.booking_extension_data(19, JSON.parse({planner_group_id: "  "}.to_json).as_h)
  exec(:preview_booking, 19).get["planner_group_id"].should eq "group-aecb"
  settings({building_id: "zone-aecb", planner_group_id: "", handler_emails: ["handler@example.com"]})
  requests_before = system(:Calendar)[:groups].as_a.size
  expect_raises(Exception) { exec(:provision_plan, 19).get }
  system(:Calendar)[:groups].as_a.size.should eq requests_before
  exec(:workflow_status, 19).get["planner_complete"]?.should_not eq true

  # The executable submission uses the frontend's field names and merges only
  # those fields, retaining organiser choices and the requested Planner group.
  staff.booking_extension_data(20, JSON.parse({vip_confirmed: false, planner_group_id: "group-booking", gift: true}.to_json).as_h)
  expect_raises(Exception) do
    exec(:submit_confirmation, 20, "Dr", "  ", "123", "Assistant", "456", "Officer", "789", "ABC", "Private", "standard").get
  end
  expect_raises(Exception) do
    exec(:submit_confirmation, 20, "Dr", "Guest", "123", "Assistant", "456", "Officer", "789", "ABC", "Private", "invalid").get
  end
  exec(:get_booking, 20).get["extension_data"]["vip_confirmed"].should eq false
  messages_before = system(:Mailer)[:templates].as_a.size
  exec(:submit_confirmation, 20, "Dr", "Confirmed Guest", "123", "Assistant", "456", "Officer", "789", "ABC", "Private", " Custom ", "Green tea").get
  submission = exec(:get_booking, 20).get["extension_data"]
  submission["vip_confirmed"].should eq true
  submission["vip_full_name"].should eq "Confirmed Guest"
  submission["vip_contact_number"].should eq "123"
  submission["assistant_name"].should eq "Assistant"
  submission["assistant_contact_number"].should eq "456"
  submission["protocol_officer_contact_number"].should eq "789"
  submission["beverage_preference"].should eq "custom"
  submission["beverage_notes"].should eq "Green tea"
  submission["gift"].should eq true
  submission["planner_group_id"].should eq "group-booking"
  system(:StaffAPI)[:signal_changes].should eq false
  system(:Mailer)[:templates].as_a.size.should eq messages_before + 1
  system(:Mailer)[:last_args]["vip_contact_number"].should eq "123"
  system(:Calendar)[:tasks].as_a.map(&.as_s).any?(&.ends_with?("Welcome Beverage - custom: Green tea")).should be_true
  exec(:workflow_status, 20).get["planner_complete"].should eq true
  plans_before = system(:Calendar)[:plans].as_a.size
  exec(:submit_confirmation, 20, "Dr", "Confirmed Guest", "123", "Assistant", "456", "Officer", "789", "ABC", "Private", "custom", "Green tea").get
  system(:Calendar)[:plans].as_a.size.should eq plans_before
  system(:Mailer)[:templates].as_a.size.should eq messages_before + 1

  # Form notes are authoritative, including empty strings. A previous custom
  # request must not reappear after the assistant selects standard or clears it.
  {21_i64 => "standard", 22_i64 => "custom"}.each do |id, preference|
    staff.booking_extension_data(id, JSON.parse({
      vip_confirmed: false, planner_group_id: "group-booking",
      welcome_beverage: "custom", welcome_beverage_notes: "Old tea", welcome_beverage_custom: "Old coffee",
    }.to_json).as_h)
    exec(:submit_confirmation, id, "Dr", "Confirmed Guest", "123", "Assistant", "456", "Officer", "789", "ABC", "Private", preference, "").get
    booking = exec(:get_booking, id).get
    booking["extension_data"]["beverage_notes"].should eq ""
    booking["extension_data"]["welcome_beverage_custom"].should eq "Old coffee"
    plan_id = exec(:workflow_status, id).get["plan_id"].as_s
    tasks = system(:Calendar)[:tasks].as_a.map(&.as_s).select(&.starts_with?("#{plan_id}:"))
    tasks.size.should eq 1
    tasks.first.ends_with?("Welcome Beverage - #{preference}").should be_true
  end
end
