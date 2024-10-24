require "placeos-driver/spec"
require "email"

class StaffAPI < DriverSpecs::MockDriver
  #   ZONES = [
  #     {
  #       created_at:   1660537814,
  #       updated_at:   1681800971,
  #       id:           "zone-1234",
  #       name:         "Test Org Zone",
  #       display_name: "Test Org Zone",
  #       location:     "",
  #       description:  "",
  #       code:         "",
  #       type:         "",
  #       count:        0,
  #       capacity:     0,
  #       map_id:       "",
  #       tags:         [
  #         "org",
  #       ],
  #       triggers:  [] of String,
  #       parent_id: "zone-0000",
  #       timezone:  "Australia/Sydney",
  #     },
  #     {
  #       created_at:   1660537814,
  #       updated_at:   1681800971,
  #       id:           "zone-1234",
  #       name:         "Test Building Zone",
  #       display_name: "Test Building Zone",
  #       location:     "",
  #       description:  "",
  #       code:         "",
  #       type:         "",
  #       count:        0,
  #       capacity:     0,
  #       map_id:       "",
  #       tags:         [
  #         "building",
  #       ],
  #       triggers:  [] of String,
  #       parent_id: "zone-0000",
  #       timezone:  "Australia/Sydney",
  #     },
  #   ]

  #   METADATA_TEMPLATES = {
  #     email_templates = {
  #       name:        "email_templates",
  #       description: "Email Templates for Zone",
  #       details:     [
  #         {
  #           id:         "template-1",
  #           from:       "support@example.com",
  #           html:       "<p>This is a test template</p>",
  #           text:       "This is a test template",
  #           subject:    "Test 1",
  #           trigger:    "visitor_invited.visitor",
  #           zone_id:    "zone-1234",
  #           category:   "internal",
  #           reply_to:   "noreply@example.com",
  #           created_at: 1725519680,
  #           updated_at: 1725519680,
  #         },
  #         {
  #           id:         "template-2",
  #           from:       "support@example.com",
  #           html:       "<p>This is a test template</p>",
  #           text:       "This is a test template",
  #           subject:    "Test 2",
  #           trigger:    "visitor_invited.event",
  #           zone_id:    "zone-1234",
  #           category:   "internal",
  #           reply_to:   "noreply@example.com",
  #           created_at: 1727745875,
  #           updated_at: 1727745875,
  #         },
  #       ],
  #       parent_id:      "zone-1234",
  #       editors:        [] of String,
  #       modified_by_id: "user-1234",
  #     },
  #   }

  #   def zones(q : String? = nil,
  #             limit : Int32 = 1000,
  #             offset : Int32 = 0,
  #             parent : String? = nil,
  #             tags : Array(String) | String? = nil)
  #     zones = ZONES
  #     zones = zones.select { |zone| zone["tags"].includes?(tags) } if tags.is_a?(String)
  #     JSON.parse(zones.to_json)
  #   end

  #   def metadata(id : String, key : String? = nil)
  #     case key
  #     when "email_templates"
  #       JSON.parse(METADATA_TEMPLATES.to_json)
  #     when "email_template_fields"
  #       nil
  #     else
  #       nil
  #     end
  #   end
end

class Mailer < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  def on_load
    self[:sent] = 0
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  )
    self[:sent] = self[:sent].as_i + 1
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
    from : String | Array(String) | Nil = nil
  ) : Bool
    true
  end
end

DriverSpecs.mock_driver "Place::TemplateMailer" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
  })

  # _resp = exec(:send_survey_emails).get
  # system(:Mailer_1)[:sent].should eq 3
end

#   settings({
#     sender:   "support@place.tech",
#     host:     ENV["PLACE_SMTP_HOST"]? || "localhost",
#     port:     ENV["PLACE_SMTP_PORT"]?.try(&.to_i) || 25,
#     username: ENV["PLACE_SMTP_USER"]? || "", # Username/Password for SMTP servers with basic authorization
#     password: ENV["PLACE_SMTP_PASS"]? || "",
#     tls_mode: ENV["PLACE_SMTP_MODE"]? || "none",

#     email_templates: {visitor: {checkin: {
#       subject: "%{name} has arrived",
#       text:    "for your meeting at %{time}",
#     }}},
#   })

#   response = exec(
#     :send_mail,
#     subject: "Test Email",
#     to: ENV["PLACE_TEST_EMAIL"]? || "support@place.tech",
#     message_plaintext: "Hello!",
#   ).get

#   response.should be_true

#   response = exec(
#     :send_template,
#     to: "steve@place.tech",
#     template: {"visitor", "checkin"},
#     args: {
#       name: "Bob",
#       time: "1:30pm",
#     }
#   ).get

#   response.should be_true

#   # Convert settings template to metadata template
#   response = exec(
#     :templates_to_metadata,
#     templates: {visitor_invited: {
#       event: {
#         subject: "You have been invited to %{event_title}",
#         text:    "Please be there at ${event_time}",
#       },
#       booking: {
#         subject: "You have a booking with %{host_name}",
#         text:    "Please be there at ${booking_time}",
#       },
#     }}
#   ).get

#   response.should be_truthy

#   response.not_nil!.as_a[0].as_h.keys.should contain("zone_id")
#   response.not_nil!.as_a[0].as_h.keys.should contain("created_at")
#   response.not_nil!.as_a[0].as_h.keys.should contain("updated_at")
#   response.not_nil!.as_a[0].as_h.keys.should contain("id")

#   response.not_nil!.as_a[0]["trigger"]?.should eq("visitor_invited.event")
#   response.not_nil!.as_a[0]["subject"]?.should eq("You have been invited to %{event_title}")
#   response.not_nil!.as_a[0]["text"]?.should eq("Please be there at ${event_time}")

#   response.not_nil!.as_a[1]["trigger"]?.should eq("visitor_invited.booking")
#   response.not_nil!.as_a[1]["subject"]?.should eq("You have a booking with %{host_name}")
#   response.not_nil!.as_a[1]["text"]?.should eq("Please be there at ${booking_time}")

#   # Convert metadata template to settings template
#   response = exec(
#     :templates_to_mailer,
#     templates: [
#       {
#         "trigger" => "visitor_invited.event",
#         "subject" => "You have been invited to %{event_title}",
#         "text"    => "Please be there at ${event_time}",
#       },
#       {
#         "trigger" => "visitor_invited.booking",
#         "subject" => "You have a booking with %{host_name}",
#         "text"    => "Please be there at ${booking_time}",
#       },
#     ]
#   ).get

#   response.should be_truthy

#   response.not_nil!.as_h["visitor_invited"]["event"]["subject"]?.should eq("You have been invited to %{event_title}")
#   response.not_nil!.as_h["visitor_invited"]["event"]["text"]?.should eq("Please be there at ${event_time}")

#   response.not_nil!.as_h["visitor_invited"]["booking"]["subject"]?.should eq("You have a booking with %{host_name}")
#   response.not_nil!.as_h["visitor_invited"]["booking"]["text"]?.should eq("Please be there at ${booking_time}")

#   # get zones
#   response = exec(:get_org_zone?).get
#   response.not_nil!.as_h["id"].should eq "zone-1234"
#   response = exec(:get_building_zone?).get
#   response.not_nil!.as_h["id"].should eq "zone-1234"

#   # Merge setting and metadata templates
#   response = exec(:get_templates).get
