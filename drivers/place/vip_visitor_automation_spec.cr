require "placeos-driver/spec"
require "placeos-driver/interface/mailer"
require "base64"

class VIPStaffMock < DriverSpecs::MockDriver
  @start = (Time.utc + 1.day).to_unix
  @pending_offset = 0_i64

  def postpone_pending
    @pending_offset = 3600_i64
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    id = booking_id.to_i64
    start = @start + (id == 1 ? @pending_offset : 0_i64)
    booking = JSON.parse({
      id: id, booking_type: "vip-visitor", booking_start: start,
      booking_end: start + 3600, zones: ["zone-aecb"], title: "VIP Guest",
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
    booking
  end
end

class VIPCalendarMock < DriverSpecs::MockDriver
  @plans = [] of String
  @buckets = [] of String
  @tasks = [] of String
  @failed_once = false

  def on_load
    self[:plans] = @plans
    self[:buckets] = @buckets
    self[:tasks] = @tasks
  end

  def create_plan(group_id : String, title : String)
    raise "wrong group" unless group_id == "group-aecb"
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

  def on_load
    self[:recipients] = @recipients
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
  exec(:process_booking, 9).get
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
    handler_emails: ["handler@example.com"], notify_arrival_departure: true,
    notification_emails: ["manager@example.com"],
    planner_task_assignments: {meet_greet: ["user-greeter"]},
  })
  publish("staff/booking/changed", {id: 15, action: "checked_in", checked_in: true}.to_json)
  sleep 0.5
  publish("staff/guest/checkin", {booking_id: 15, action: "checkin", checkin: true}.to_json)
  sleep 0.5
  system(:Mailer)[:recipients].as_a.count { |email| email == "manager@example.com" }.should eq 1
  publish("staff/guest/checkin", {booking_id: 15, action: "checkin", checkin: false}.to_json)
  sleep 0.5
  publish("staff/booking/changed", {id: 15, action: "checked_in", checked_in: false}.to_json)
  sleep 0.5
  system(:Mailer)[:recipients].as_a.count { |email| email == "manager@example.com" }.should eq 2

  # Editing a pending visit refreshes its invitation, without accepting it.
  system(:StaffAPI).as(VIPStaffMock).postpone_pending
  exec(:process_booking, 1).get
  system(:Mailer)[:recipients].as_a.count { |email| email == "assistant@example.net" }.should eq 2
  system(:Calendar)[:plans].as_a.size.should eq 7
  exec(:process_booking, 1).get
  system(:Mailer)[:recipients].as_a.count { |email| email == "assistant@example.net" }.should eq 2
end
