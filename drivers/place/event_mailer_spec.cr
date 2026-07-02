require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# A single event whose organizer (host) should become the reply-to.
EVENT = {
  id:          "evt-1",
  host:        "organizer@org.com",
  title:       "Welcome Meeting",
  event_start: Time.utc.to_unix,
  event_end:   (Time.utc + 1.hour).to_unix,
  location:    "Room 1",
  attendees:   [{name: "Organizer", email: "organizer@org.com"}],
  attachments: [] of String,
  private:     false,
  all_day:     false,
}

class StaffAPI < DriverSpecs::MockDriver
  # the event mailer subscribes to systems returned here; returning the spec's
  # own system id makes it subscribe to the local Bookings mock below.
  def systems(zone_id : String? = nil)
    JSON.parse([{id: "spec_runner_system"}].to_json)
  end

  def patch_event_metadata(system_id : String, event_id : String, metadata : JSON::Any)
    self[:patched] = event_id
    JSON.parse({metadata: metadata}.to_json)
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
    self[:to] = to
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
    true
  end
end

class Bookings < DriverSpecs::MockDriver
  def on_load
    self[:bookings] = [EVENT]
  end
end

DriverSpecs.mock_driver "Place::EventMailer" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
    Bookings: {Bookings},
  })

  settings({
    zone_ids_to_target:   ["zone-1"],
    module_to_target:     "Bookings_1",
    event_filter:         "", # no time filtering
    email_template_group: "events",
    email_template:       "welcome",
  })

  sleep 1

  # the welcome email's reply-to should be the event organizer
  system(:Mailer)[:to].should eq ["organizer@org.com"]
  system(:Mailer)[:reply_to].should eq "organizer@org.com"
end
