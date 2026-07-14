require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

DriverSpecs.mock_driver "Place::BookingApprovalWorkflows" do
  system({
    StaffAPI: {StaffAPIMock},
    Mailer:   {MailerMock},
  })

  settings({
    booking_type:    "desk",
    notify_managers: false,
    approval_type:   {
      "zone-1" => {
        approval:      "manager_approval",
        name:          "Test Building",
        support_email: "support@org.com",
        attachments:   nil,
      },
    },
  })

  now = Time.utc.to_unix
  payload = {
    action:          "cancelled",
    id:              1,
    booking_type:    "desk",
    booking_start:   now + 3600,
    booking_end:     now + 7200,
    asset_id:        "desk-1",
    user_id:         "user-1",
    user_email:      "user@org.com",
    user_name:       "User One",
    zones:           ["zone-1"],
    booked_by_name:  "Booker",
    booked_by_email: "booker@org.com",
  }.to_json

  publish("staff/booking/changed", payload)
  sleep 1

  # the cancellation email's reply-to should be the person who created the booking
  system(:Mailer)[:template].should eq ["bookings", "cancelled"]
  system(:Mailer)[:to].should eq "user@org.com"
  system(:Mailer)[:reply_to].should eq "booker@org.com"
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

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
    true
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
    self[:template] = template
    self[:to] = to
    self[:reply_to] = reply_to
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
end
