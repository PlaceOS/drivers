require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# Auto check-in: people are present, so the meeting is started automatically.
DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  system({
    Bookings: {BookingsMock},
  })

  sleep 2

  system(:Bookings_1)[:current_pending].should eq(false)
end

# No-show prompt: nobody present after the prompt window, so the host is
# emailed -- and the reply-to is set to the host.
DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  system({
    Bookings: {PromptBookingsMock},
    Mailer:   {CheckInMailerMock},
    Calendar: {CheckInCalendarMock},
  })

  sleep 2

  system(:Mailer)[:template].should eq ["bookings", "check_in_prompt"]
  system(:Mailer)[:to].should eq "host@org.com"
  # replies to the check-in prompt go to the host
  system(:Mailer)[:reply_to].should eq "host@org.com"
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:current_booking] = {
      event_start: 6.minutes.ago.to_unix,
      attendees:   [] of String,
      private:     false,
      all_day:     false,
      attachments: [] of String,
    }
    self[:current_pending] = true
    self[:presence] = true
  end

  def start_meeting(time : Int64)
    self[:current_pending] = false
  end
end

# :nodoc:
class PromptBookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:current_booking] = {
      id:          "evt-1",
      host:        "host@org.com",
      title:       "Standup",
      event_start: 15.minutes.ago.to_unix,
      event_end:   15.minutes.from_now.to_unix,
      attendees:   [{name: "Host", email: "host@org.com", organizer: true}],
      private:     false,
      all_day:     false,
      attachments: [] of String,
    }
    self[:sensor_stale] = false
    self[:presence] = false
    self[:current_pending] = true
  end

  def people_present?
    0.0
  end

  def start_meeting(time : Int64)
    self[:current_pending] = false
  end
end

# :nodoc:
class CheckInMailerMock < DriverSpecs::MockDriver
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
class CheckInCalendarMock < DriverSpecs::MockDriver
  def get_user(email : String)
    {name: "Host", email: email}
  end
end
