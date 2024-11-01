require "placeos-driver/spec"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"

class StaffAPI < DriverSpecs::MockDriver
  ZONES = [
    {
      created_at:   1660537814,
      updated_at:   1681800971,
      id:           "zone-org-1234",
      name:         "Test Org Zone",
      display_name: "Test Org Zone",
      location:     "",
      description:  "",
      code:         "",
      type:         "",
      count:        0,
      capacity:     0,
      map_id:       "",
      tags:         [
        "org",
      ],
      triggers:  [] of String,
      parent_id: "zone-0000",
      timezone:  "Australia/Sydney",
    },
    {
      created_at:   1660537814,
      updated_at:   1681800971,
      id:           "zone-bld-1234",
      name:         "Test Building Zone",
      display_name: "Test Building Zone",
      location:     "",
      description:  "",
      code:         "",
      type:         "",
      count:        0,
      capacity:     0,
      map_id:       "",
      tags:         [
        "building",
      ],
      triggers:  [] of String,
      parent_id: "zone-0000",
      timezone:  "Australia/Sydney",
    },
  ]

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

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    zones = ZONES
    zones = zones.select { |zone| zone["tags"].includes?(tags) } if tags.is_a?(String)
    JSON.parse(zones.to_json)
  end

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
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil
  )
    self[:sent] = self[:sent].as_i + 1
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
    reply_to : String | Array(String) | Nil = nil
  ) : Bool
    self[:sent] = self[:sent].as_i + 1
    true
  end
end

DriverSpecs.mock_driver "Place::TemplateMailer" do
  # system({
  #   StaffAPI: {StaffAPI},
  #   Mailer_1:   {Mailer},
  #   Mailer_2:   {Mailer},
  # })

  # Missing hash key: "mod-Mailer/2" (KeyError)
  # system(:Mailer_2)[:sent].should eq 0
end
