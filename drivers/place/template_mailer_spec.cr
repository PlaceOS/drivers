require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# The TemplateMailer under test has `generic_name :Mailer`, so it occupies the
# Mailer_1 slot. The mock declared below becomes Mailer_2 -- the module that
# `system.implementing(Interface::Mailer)[1]` forwards to.
class StaffAPI < DriverSpecs::MockDriver
  ZONES = [
    {
      id:        "zone-org",
      name:      "Test Org Zone",
      tags:      ["org"],
      parent_id: "zone-0000",
      timezone:  "Australia/Sydney",
    },
    {
      id:        "zone-building",
      name:      "Test Building Zone",
      tags:      ["building"],
      parent_id: "zone-org",
      timezone:  "Australia/Sydney",
    },
  ]

  # one template, with its own reply_to, triggered by "test.welcome"
  EMAIL_TEMPLATES = [
    {
      id:       "template-1",
      trigger:  "test.welcome",
      subject:  "Hi %{name}",
      text:     "Welcome %{name}",
      html:     "<p>Welcome %{name}</p>",
      from:     "noreply@org.com",
      reply_to: "template-reply@org.com",
    },
  ]

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    zones = ZONES
    zones = zones.select { |zone| zone["tags"].includes?(tags) } if tags.is_a?(String)
    JSON.parse(zones.to_json)
  end

  def metadata(id : String, key : String? = nil)
    key = key.to_s
    details = case key
              when "email_templates"
                JSON.parse(EMAIL_TEMPLATES.to_json)
              else
                # email_template_fields (and anything else): an empty object
                JSON.parse("{}")
              end

    JSON.parse({
      key => {
        name:        key,
        description: "",
        details:     details,
        parent_id:   id,
        editors:     [] of String,
      },
    }.to_json)
  end

  def write_metadata(id : String, key : String, payload : JSON::Any = JSON::Any.new(nil), description : String = "")
    JSON.parse({key => {name: key, details: payload, parent_id: id}}.to_json)
  end
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
    reply_to : String | Array(String) | Nil = nil,
  )
    self[:sent] = self[:sent].as_i + 1
    self[:reply_to] = reply_to
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
    self[:sent] = self[:sent].as_i + 1
    self[:reply_to] = reply_to
    true
  end
end

DriverSpecs.mock_driver "Place::TemplateMailer" do
  # The TemplateMailer under test forwards to `system.implementing(Mailer)[1]`.
  # In production that index 1 is the next mailer in the chain (e.g. SMTP); here
  # we declare two mock mailers so index 1 is the recording mock (Mailer_2).
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer, Mailer},
  })

  # 1. With no configured reply_to, a per-template reply_to overrides the host
  #    reply_to passed in by the caller.
  exec(
    :send_template,
    to: "steve@org.com",
    template: {"test", "welcome"},
    args: {name: "Bob"},
    reply_to: "host@org.com",
  ).get
  system(:Mailer_2)[:reply_to].should eq "template-reply@org.com"

  # 2. With no template match and no configured reply_to, the host reply_to is
  #    forwarded through to the downstream mailer.
  exec(
    :send_template,
    to: "steve@org.com",
    template: {"no", "template"},
    args: {name: "Bob"},
    reply_to: "host@org.com",
  ).get
  system(:Mailer_2)[:reply_to].should eq "host@org.com"

  # 3. A reply_to configured on the TemplateMailer overrides BOTH the
  #    per-template reply_to and the host reply_to passed in by the caller.
  settings({
    reply_to: "tenant@org.com",
  })

  exec(
    :send_template,
    to: "steve@org.com",
    template: {"test", "welcome"},
    args: {name: "Bob"},
    reply_to: "host@org.com",
  ).get
  system(:Mailer_2)[:reply_to].should eq "tenant@org.com"
end
