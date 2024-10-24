require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  system({
    Mailer:   {MailerMock},
    Calendar: {CalendarMock},
    StaffAPI: {StaffAPIMock},
  })

  exec(:check_bookings).get

  system(:StaffAPI)[:queries].should eq 4
  system(:StaffAPI)[:booking_state].should eq "1--notified"
  system(:Mailer)[:template].should eq ["bookings", "booking_notify"]
  system(:Mailer)[:to].should eq ["concierge@place.com", "user1234@org.com", "manager@site.com"]
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  # need this for the interface
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
  )
    true
  end

  # we don't have templates defined so we'll override this for testing
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
    self[:template] = template
    self[:to] = to
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_user_manager(staff_email : String)
    {
      email: "manager@site.com",
    }
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @called : Int32 = 0

  def query_bookings(
    type : String,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil
  )
    logger.debug { "Querying desk bookings!" }

    @called += 1
    self[:queries] = @called
    return [] of String if @called >= 2

    now = Time.local
    start = now.at_beginning_of_day.to_unix
    ending = now.at_end_of_day.to_unix
    [{
      id:              1,
      booking_type:    type,
      booking_start:   start,
      booking_end:     ending,
      asset_id:        "desk-123",
      user_id:         "user-1234",
      user_email:      "user1234@org.com",
      user_name:       "Bob Jane",
      zones:           zones + ["zone-building"],
      checked_in:      true,
      rejected:        false,
      booked_by_name:  "Bob Jane",
      booked_by_email: "user1234@org.com",
    }]
  end

  def booking_state(booking_id : String | Int64, state : String)
    self[:booking_state] = "#{booking_id}--#{state}"
    true
  end
end
