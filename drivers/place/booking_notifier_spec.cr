require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# Desk booking fixture anchored to the current time, so the reminder offsets
# (which the driver compares against Time.utc) can be exercised deterministically
def reminder_booking(
  id : Int32,
  starts_in : Time::Span,
  email : String,
  created : Time? = nil,
  checked_in : Bool = false,
)
  starting = Time.utc + starts_in
  {
    id:              id,
    booking_type:    "desk",
    booking_start:   starting.to_unix,
    booking_end:     (starting + 8.hours).to_unix,
    asset_id:        "desk-#{id}",
    user_id:         "user-#{id}",
    user_email:      email,
    user_name:       "Person #{id}",
    zones:           ["zone-building"],
    checked_in:      checked_in,
    rejected:        false,
    created:         created.try(&.to_unix),
    booked_by_name:  "Booker #{id}",
    booked_by_email: "booker-#{id}@org.com",
  }
end

DriverSpecs.mock_driver "Place::BookingNotifier" do
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
  # replies should go to the person who created the booking, not the PlaceOS sender
  system(:Mailer)[:reply_to].should eq "user1234@org.com"

  # ============================ booking reminders ============================

  reminder_settings = {
    booking_type:             "desk",
    poll_bookings:            false,
    poll_every_minutes:       5,
    reminder_schedule:        "", # driven by exec below rather than the cron
    reminder_grace_minutes:   30,
    reminders_before_booking: [60],
    notify:                   {
      zone_id1: {
        name:                 "Sydney Building 1",
        email:                ["concierge@place.com"],
        notify_manager:       true,
        notify_booking_owner: true,
      },
    },
  }

  # starts inside the 60 minute offset (45 seconds before the start, the grace
  # window is 30 minutes) => reminder due
  due = reminder_booking(id: 11, starts_in: 45.seconds, email: "due@org.com")
  # starts outside the 60 minute offset => no reminder yet
  not_yet_due = reminder_booking(id: 12, starts_in: 2.hours, email: "later@org.com")
  # booked 10 seconds ago for a start 45 seconds away, so the 60 minute
  # reminder moment had already passed when it was booked => skipped
  booked_too_late = reminder_booking(
    id: 13,
    starts_in: 45.seconds,
    email: "late@org.com",
    created: Time.utc - 10.seconds
  )
  # already on site => skipped
  on_site = reminder_booking(id: 14, starts_in: 45.seconds, email: "onsite@org.com", checked_in: true)

  system(:StaffAPI_1).as(StaffAPIMock).set_reminders(
    [due, not_yet_due, booked_too_late, on_site].map { |booking| JSON.parse(booking.to_json) }
  )

  settings(reminder_settings)

  exec(:send_booking_reminders).get

  system(:Mailer)[:reminders].should eq 1
  system(:Mailer)[:template].should eq ["bookings", "booking_reminder"]
  system(:Mailer)[:to].should eq "due@org.com"
  # replies should go to the person who created the booking, not the PlaceOS sender
  system(:Mailer)[:reply_to].should eq "booker-11@org.com"
  status[:reminders_sent_count].should eq 1

  # a second sweep does not send the same reminder again
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 1
  status[:reminders_sent_count].should eq 1

  # moving the offset out to 2 hours catches the booking that wasn't due yet,
  # and the booking that was skipped is still skipped
  settings(reminder_settings.merge({reminders_before_booking: [7200]}))
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 2
  system(:Mailer)[:to].should eq "later@org.com"
  system(:Mailer)[:reply_to].should eq "booker-12@org.com"
  status[:reminders_sent_count].should eq 2

  # the reminder trigger is advertised to the template mailer
  triggers = exec(:template_fields).get.not_nil!.as_a.map { |fields| fields["trigger"].as_a.map(&.as_s).join(".") }
  triggers.should contain "bookings.booking_notify"
  triggers.should contain "bookings.booking_reminder"
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  @reminders : Int32 = 0

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
    reply_to : String | Array(String) | Nil = nil,
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
    reply_to : String | Array(String) | Nil = nil,
  )
    self[:template] = template
    self[:to] = to
    self[:reply_to] = reply_to

    if template[1].starts_with?("booking_reminder")
      @reminders += 1
      self[:reminders] = @reminders
    end
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
  @reminders : Array(JSON::Any) = [] of JSON::Any

  # bookings returned by query_bookings once reminders have been configured
  def set_reminders(bookings : Array(JSON::Any))
    @reminders = bookings
  end

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
    checked_in : Bool? = nil,
  )
    logger.debug { "Querying desk bookings!" }

    @called += 1
    self[:queries] = @called

    # a reminder sweep queries each zone twice (approved and not yet approved),
    # so the fixtures come back on the first query of each pair
    unless @reminders.empty?
      return @reminders if @called.odd?
      return [] of JSON::Any
    end

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

  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    self[:booking_state] = "#{booking_id}--#{state}"
    true
  end
end
