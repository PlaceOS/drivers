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
  type : String = "desk",
  asset_id : String? = nil,
)
  starting = Time.utc + starts_in
  {
    id:              id,
    booking_type:    type,
    booking_start:   starting.to_unix,
    booking_end:     (starting + 8.hours).to_unix,
    asset_id:        asset_id || "desk-#{id}",
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
    Mailer:           {MailerMock},
    Calendar:         {CalendarMock},
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
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
        attachments:          {"welcome.pdf" => "https://s3.example.com/welcome.pdf"},
      },
    },
  }

  # starts 45 minutes from now, inside the 60 minute offset and its 30 minute
  # grace window => reminder due
  due = reminder_booking(id: 11, starts_in: 45.minutes, email: "due@org.com")
  # starts outside the 60 minute offset => no reminder yet
  not_yet_due = reminder_booking(id: 12, starts_in: 100.minutes, email: "later@org.com")
  # booked 10 minutes ago for a start 45 minutes away, so the 60 minute
  # reminder moment had already passed when it was booked => skipped
  booked_too_late = reminder_booking(
    id: 13,
    starts_in: 45.minutes,
    email: "late@org.com",
    created: Time.utc - 10.minutes
  )
  # already on site => skipped
  on_site = reminder_booking(id: 14, starts_in: 45.minutes, email: "onsite@org.com", checked_in: true)
  # the 60 minute offset passed 40 minutes ago, beyond the 30 minute grace
  # window (i.e. the driver was offline) => skipped rather than sent late
  stale = reminder_booking(id: 19, starts_in: 20.minutes, email: "stale@org.com")

  system(:StaffAPI_1).as(StaffAPIMock).set_reminders(
    [due, not_yet_due, booked_too_late, on_site, stale].map { |booking| JSON.parse(booking.to_json) }
  )

  # arming the schedule in settings sweeps immediately, so the reminders due
  # right after a restart are picked up without waiting for the cron interval
  settings(reminder_settings.merge({reminder_schedule: "*/15 * * * *"}))

  50.times do
    break if status["reminders_sent_count"]?.try(&.as_i) == 1
    sleep 100.milliseconds
  end

  system(:Mailer)[:reminders].should eq 1
  system(:Mailer)[:template].should eq ["bookings", "booking_reminder"]
  system(:Mailer)[:to].should eq "due@org.com"
  # replies should go to the person who created the booking, not the PlaceOS sender
  system(:Mailer)[:reply_to].should eq "booker-11@org.com"
  status[:reminders_sent_count].should eq 1

  # every merge field advertised for the reminder is supplied
  reminder_args = system(:Mailer)[:args].as_h
  reminder_args["reminder_offset_minutes"].as_i.should eq 60
  reminder_args["attachment_name"].as_s.should eq "welcome.pdf"
  reminder_args["attachment_url"].as_s.should eq "https://s3.example.com/welcome.pdf"
  reminder_args["approver_name"].raw.should be_nil
  # zone attachments follow disable_attachments (default true) => no files attached
  system(:Mailer)[:attachments].as_a.should be_empty

  # disarm the schedule so only exec drives the sweeps below, and a manual
  # sweep after the scheduled one does not send the same reminder again
  settings(reminder_settings)
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 1
  status[:reminders_sent_count].should eq 1

  # moving the offset out to 2 hours catches the booking that wasn't due yet,
  # and the bookings that were skipped are still skipped
  settings(reminder_settings.merge({reminders_before_booking: [120]}))
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 2
  system(:Mailer)[:to].should eq "later@org.com"
  system(:Mailer)[:reply_to].should eq "booker-12@org.com"
  status[:reminders_sent_count].should eq 2

  # a zone that does not notify the booking owner gets no reminders either
  ownerless_due = reminder_booking(id: 15, starts_in: 45.minutes, email: "no-flag@org.com")
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([ownerless_due].map { |booking| JSON.parse(booking.to_json) })
  settings(reminder_settings.merge({
    notify: {zone_id1: {name: "Sydney Building 1", email: ["concierge@place.com"]}},
  }))
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 2
  status[:reminders_sent_count].should eq 2

  # a visitor booking is queried as a visitor booking and reminded at the
  # host's address, using the booking type specific template name
  visitor_due = reminder_booking(
    id: 16,
    starts_in: 45.minutes,
    email: "host@org.com",
    type: "visitor",
    asset_id: "guest@visitor.com"
  )
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([visitor_due].map { |booking| JSON.parse(booking.to_json) })
  settings(reminder_settings.merge({booking_type: "visitor", unique_templates: true}))
  exec(:send_booking_reminders).get

  system(:StaffAPI)[:last_type].should eq "visitor"
  system(:Mailer)[:reminders].should eq 3
  system(:Mailer)[:template].should eq ["bookings", "booking_reminder_visitor"]
  system(:Mailer)[:to].should eq "host@org.com"
  system(:Mailer)[:reply_to].should eq "booker-16@org.com"
  status[:reminders_sent_count].should eq 3

  # the reminder trigger is advertised to the template mailer
  triggers = exec(:template_fields).get.not_nil!.as_a
  trigger_names = triggers.map { |fields| fields["trigger"].as_a.map(&.as_s).join(".") }
  trigger_names.should contain "bookings.booking_notify_visitor"
  trigger_names.should contain "bookings.booking_reminder_visitor"

  reminder_fields = triggers.find { |fields| fields["trigger"].as_a.map(&.as_s).join(".") == "bookings.booking_reminder_visitor" }
  field_names = reminder_fields.not_nil!["fields"].as_a.map { |field| field["name"].as_s }
  field_names.should contain "reminder_offset_minutes"
  field_names.should contain "attachment_name"
  # a reminder must never rotate the network password handed out by the booking email
  field_names.includes?("network_username").should be_false
  field_names.includes?("network_password").should be_false
  # every merge field advertised for the reminder is present in the arguments
  # that were actually sent, so no placeholder can reach the email
  # unsubstituted (the field list is shared by every booking type)
  field_names.sort.should eq system(:Mailer)[:args].as_h.keys.sort

  # two offsets open at the same time on one booking => one reminder each,
  # each carrying its own offset, sent in ascending order of the offsets
  multi_due = reminder_booking(id: 17, starts_in: 40.minutes, email: "multi@org.com")
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([multi_due].map { |booking| JSON.parse(booking.to_json) })
  settings(reminder_settings.merge({reminders_before_booking: [60, 45]}))
  exec(:send_booking_reminders).get

  system(:Mailer)[:reminders].should eq 5
  system(:Mailer)[:to].should eq "multi@org.com"
  system(:Mailer)[:offsets].as_a.last(2).map(&.as_i).should eq [45, 60]
  status[:reminders_sent_count].should eq 5

  # a locker booking is queried as a locker booking and reminded at the
  # owner's address with the locker specific template name
  locker_due = reminder_booking(id: 18, starts_in: 45.minutes, email: "locker@org.com", type: "locker", asset_id: "lock-1")
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([locker_due].map { |booking| JSON.parse(booking.to_json) })
  settings(reminder_settings.merge({
    booking_type:             "locker",
    unique_templates:         true,
    reminders_before_booking: [60],
  }))
  exec(:send_booking_reminders).get

  system(:StaffAPI)[:last_type].should eq "locker"
  system(:Mailer)[:reminders].should eq 6
  system(:Mailer)[:template].should eq ["bookings", "booking_reminder_locker"]
  system(:Mailer)[:to].should eq "locker@org.com"
  system(:Mailer)[:offsets].as_a.last.as_i.should eq 60
  status[:reminders_sent_count].should eq 6

  # the locker booking moved to a new start time => reminded about the new time
  locker_moved = reminder_booking(id: 18, starts_in: 50.minutes, email: "locker@org.com", type: "locker", asset_id: "lock-1")
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([locker_moved].map { |booking| JSON.parse(booking.to_json) })
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 7
  system(:Mailer)[:args].as_h["starting_unix"].as_i64.should eq locker_moved[:booking_start]
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 7

  # a zone whose bookings cannot be queried does not stop the other zones
  # being reminded, and the reminders sent are remembered for the next sweep
  failing_due = reminder_booking(id: 20, starts_in: 45.minutes, email: "failing@org.com")
  system(:StaffAPI_1).as(StaffAPIMock).set_reminders([failing_due].map { |booking| JSON.parse(booking.to_json) })
  failing_zones = reminder_settings.merge({
    notify: {
      zone_id1:     {name: "Sydney Building 1", notify_booking_owner: true},
      zone_offline: {name: "Offline Building", notify_booking_owner: true},
    },
  })
  settings(failing_zones)
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 8
  system(:Mailer)[:to].should eq "failing@org.com"
  status[:reminders_sent].as_h.keys.should contain "20.0.#{failing_due[:booking_start]}"
  exec(:send_booking_reminders).get
  system(:Mailer)[:reminders].should eq 8
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  @reminders : Int32 = 0
  @offsets : Array(Int64) = [] of Int64

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
    self[:args] = args
    self[:attachments] = attachments

    if template[1].starts_with?("booking_reminder")
      @reminders += 1
      self[:reminders] = @reminders
      offset = args["reminder_offset_minutes"]?
      @offsets << offset.as(Int64) if offset.is_a?(Int64)
      self[:offsets] = @offsets
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
class LocationServicesMock < DriverSpecs::MockDriver
  # the locker asset name lookup resolves the building through locations
  def building_id : String
    "zone-building"
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

    self[:last_type] = type
    @called += 1
    self[:queries] = @called

    # a reminder sweep queries each zone twice (approved and not yet approved),
    # so the fixtures come back on the not yet approved query
    unless @reminders.empty?
      raise "staff api unavailable for #{zones}" if zones.includes?("zone_offline")
      return @reminders if approved == false
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

  # no lockers are configured for these tests, so the locker asset name lookup
  # falls back to the asset id just as it does for desks
  def metadata(id : String, key : String? = nil)
    Hash(String, JSON::Any).new
  end
end
