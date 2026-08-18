require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

# builds the JSON the Bookings driver exposes as `current_booking`
#
# `created` is the calendar's creation time (nil == not provided by the calendar)
def build_booking(
  id : String,
  started_ago : Time::Span,
  length : Time::Span? = 30.minutes,
  created : Time? = nil,
  host : String = "host@org.com",
  mailbox : String = "room@org.com",
)
  starting = Time.utc - started_ago
  {
    id:          id,
    host:        host,
    title:       "Meeting #{id}",
    event_start: starting.to_unix,
    event_end:   length ? (starting + length).to_unix : nil,
    created:     created.try(&.to_rfc3339),
    mailbox:     mailbox,
    attendees:   [
      {name: "Host", email: host, organizer: true},
      {name: "Guest", email: "guest@org.com", organizer: false},
    ],
    private:     false,
    all_day:     length.nil?,
    attachments: [] of String,
  }
end

# settings shared by the scenarios, `auto_cancel` etc. are toggled per test
BASE_SETTINGS = {
  prompt_after:       10,
  present_from:       5,
  ignore_longer_than: 120,
  decline_message:    "Room released as nobody checked in",
  notify_staff:       {
    "cc"           => ["facilities@org.com"],
    "room@org.com" => ["room-owner@org.com", "host@org.com"],
  },
  check_in_url: "https://domain.com/meeting/check-in",
  no_show_url:  "https://domain.com/meeting/no-show",
  time_zone:    "Australia/Sydney",
}

# the channel the helper monitors for the hosts response to the prompt email
PROMPTED_CHANNEL = "#{DriverSpecs::SYSTEM_ID}/guest/bookings/prompted"

# wait for a channel subscription / remote exec round trip through redis
macro settle
  sleep 600.milliseconds
end

# (re)creates the mocked system with the requested setting overrides and returns the mocks
macro fresh_system(new_settings)
  system({
    Bookings: {BookingsMock},
    Mailer:   {MailerMock},
    Calendar: {CalendarMock},
  })
  settings(BASE_SETTINGS.merge({{new_settings}}))
  settle
  {system(:Bookings_1), system(:Mailer_1)}
end

DriverSpecs.mock_driver "Place::BookingCheckInHelper" do
  it "auto checks-in when people are present past the present_from window" do
    bookings, mailer = fresh_system({auto_cancel: false})

    bookings[:presence] = true
    bookings[:current_booking] = build_booking("evt-present", 6.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    # booking and pending updates arrive together and each apply state, checkin is idempotent
    bookings[:start_meeting_calls].as_a.size.should be >= 1
    bookings[:start_meeting_calls][0].as_i64.should eq bookings[:current_booking]["event_start"].as_i64
    bookings[:current_pending].as_bool.should eq false
    bookings[:end_meeting_calls].as_a.size.should eq 0
    mailer[:sent].as_i.should eq 0

    status[:current_meeting].should eq true
    status[:people_present].should eq true
    status[:meeting_pending].should eq false
  end

  it "waits for present_from before checking in on presence" do
    bookings, _mailer = fresh_system({auto_cancel: true})

    bookings[:presence] = true
    bookings[:current_booking] = build_booking("evt-early-presence", 30.seconds, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    # start is scheduled for +5 minutes, nothing should have happened yet
    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:current_pending].as_bool.should eq true
  end

  it "checks in on a stale sensor once present_from has passed" do
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:sensor_stale] = true
    bookings[:current_booking] = build_booking("evt-stale", 6.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    # schedule.at with a time in the past fires straight away
    bookings[:start_meeting_calls].as_a.size.should be >= 1
    bookings[:end_meeting_calls].as_a.size.should eq 0
    mailer[:sent].as_i.should eq 0
  end

  it "does not prompt before prompt_after has elapsed" do
    bookings, mailer = fresh_system({auto_cancel: false})

    bookings[:current_booking] = build_booking("evt-too-soon", 30.seconds, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false
  end

  it "prompts the host by email when nobody has shown up" do
    bookings, mailer = fresh_system({auto_cancel: false})

    bookings[:current_booking] = build_booking("evt-prompt", 15.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 1
    mailer[:template].should eq ["bookings", "check_in_prompt"]
    mailer[:to].should eq "host@org.com"
    # replies to the check-in prompt go to the host
    mailer[:reply_to].should eq "host@org.com"
    # global cc list + mailbox specific list, host removed, only organizers added
    mailer[:cc].as_a.map(&.as_s).sort.should eq ["facilities@org.com", "room-owner@org.com"]

    args = mailer[:args]
    args["host_email"].should eq "host@org.com"
    args["host_name"].should eq "Host"
    args["event_id"].should eq "evt-prompt"
    args["system_id"].should eq DriverSpecs::SYSTEM_ID
    args["meeting_room_name"].should eq "Spec Runner"
    args["meeting_summary"].should eq "Meeting evt-prompt"
    args["check_in_url"].should eq "https://domain.com/meeting/check-in"
    args["no_show_url"].should eq "https://domain.com/meeting/no-show"
    # no private key configured so no token
    args["jwt"].should eq nil

    status[:prompted].should eq true
    status[:responded].should eq false
    status[:checked_in].should eq false
    status[:no_show].should eq false

    # prompting doesn't touch the booking
    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0

    # further state changes don't re-prompt
    bookings[:presence] = false
    bookings[:sensor_stale] = false
    bookings.signal_status(:presence)
    settle
    mailer[:sent].as_i.should eq 1

    # host clicks check-in
    publish(PROMPTED_CHANNEL, {id: "evt-prompt", check_in: true}.to_json)
    settle

    status[:responded].should eq true
    status[:checked_in].should eq true
    status[:no_show].should eq false
    bookings[:start_meeting_calls].as_a.size.should be >= 1
    bookings[:end_meeting_calls].as_a.size.should eq 0
  end

  it "declines the meeting when the host responds no-show" do
    bookings, mailer = fresh_system({auto_cancel: false})

    bookings[:current_booking] = build_booking("evt-decline", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 1
    status[:prompted].should eq true

    # a response for some other meeting is ignored
    publish(PROMPTED_CHANNEL, {id: "evt-other", check_in: false}.to_json)
    settle
    status[:responded].should eq false
    bookings[:end_meeting_calls].as_a.size.should eq 0

    publish(PROMPTED_CHANNEL, {id: "evt-decline", check_in: false}.to_json)
    settle

    status[:responded].should eq true
    status[:no_show].should eq true
    status[:checked_in].should eq false
    bookings[:start_meeting_calls].as_a.size.should eq 0
    calls = bookings[:end_meeting_calls].as_a
    calls.size.should eq 1
    calls[0]["meeting_start_time"].as_i64.should eq bookings[:current_booking]["event_start"].as_i64
    calls[0]["notify"].as_bool.should eq true
    calls[0]["comment"].as_s.should eq "Room released as nobody checked in"

    # the booking disappears and the state is cleaned up
    bookings[:current_booking] = nil
    bookings[:current_pending] = false
    settle
    status[:current_meeting].should eq false
    status[:prompted].should eq false
    status[:no_show].should eq false
  end

  it "prompts without a decline message and cancels with the default comment" do
    bookings, mailer = fresh_system({auto_cancel: false, decline_message: nil})

    bookings[:current_booking] = build_booking("evt-default-comment", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 1
    publish(PROMPTED_CHANNEL, {id: "evt-default-comment", check_in: false}.to_json)
    settle

    status[:no_show].should eq true
    calls = bookings[:end_meeting_calls].as_a
    calls.size.should eq 1
    calls[0]["notify"].as_bool.should eq true
    # NOTE:: the mock driver strips whitespace from default argument values in its metadata
    calls[0]["comment"].as_s.should eq "cancelled at booking panel".delete(' ')
  end

  it "auto cancels a pre-booked meeting when nobody has shown up" do
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:current_booking] = build_booking("evt-auto-cancel", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    # declined with the message instead of emailing the host
    mailer[:sent].as_i.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    calls = bookings[:end_meeting_calls].as_a
    calls.size.should eq 1
    calls[0]["meeting_start_time"].as_i64.should eq bookings[:current_booking]["event_start"].as_i64
    calls[0]["notify"].as_bool.should eq true
    calls[0]["comment"].as_s.should eq "Room released as nobody checked in"

    status[:prompted].should eq true
    status[:responded].should eq true
    status[:no_show].should eq true
    status[:checked_in].should eq false

    # only cancelled once
    bookings.signal_status(:presence)
    settle
    bookings[:end_meeting_calls].as_a.size.should eq 1
  end

  it "auto cancels a pre-booked meeting on the prompt_after schedule" do
    # meeting started 9.5 minutes ago, prompt_after is 10 minutes
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:current_booking] = build_booking("evt-scheduled-cancel", 9.minutes + 57.seconds, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    bookings[:end_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false

    sleep 3.seconds
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 1
    bookings[:start_meeting_calls].as_a.size.should eq 0
    status[:no_show].should eq true
  end

  it "auto cancel emails the host as well when there is no decline message" do
    bookings, mailer = fresh_system({auto_cancel: true, decline_message: nil})

    bookings[:current_booking] = build_booking("evt-cancel-email", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 1
    mailer[:to].should eq "host@org.com"
    calls = bookings[:end_meeting_calls].as_a
    calls.size.should eq 1
    calls[0]["comment"].as_s.should eq "cancelled at booking panel".delete(' ')
    status[:no_show].should eq true
  end

  it "does not auto cancel when presence is unknown" do
    bookings, mailer = fresh_system({auto_cancel: true})
    bookings[:people_present] = nil

    bookings[:current_booking] = build_booking("evt-unknown-presence", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false
  end

  it "does not auto cancel when the sensor reports people" do
    bookings, mailer = fresh_system({auto_cancel: true})
    # presence status hasn't caught up but the query says someone is there
    bookings[:people_present] = 1.0

    bookings[:current_booking] = build_booking("evt-people-there", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false
  end

  it "does nothing when the helper is disabled" do
    bookings, mailer = fresh_system({auto_cancel: true, disable_checkin_helper: true})

    bookings[:current_booking] = build_booking("evt-disabled", 12.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    # we still track that we would have prompted so we don't spam once re-enabled
    status[:prompted].should eq true
    status[:no_show].should eq true
  end

  it "ignores long meetings" do
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:current_booking] = build_booking("evt-long", 12.minutes, length: 3.hours, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false
  end

  it "ignores all day events" do
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:current_booking] = build_booking("evt-all-day", 12.minutes, length: nil, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false
  end

  # ==============================================================
  # Bookings made after the meeting has started (walk-up bookings)
  # ==============================================================

  it "checks in a new booking that started before it was made, instead of cancelling it" do
    bookings, mailer = fresh_system({auto_cancel: true})

    # booked "now" for a slot that started 12 minutes ago
    bookings[:current_booking] = build_booking("evt-walk-up", 12.minutes, created: Time.utc)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    calls = bookings[:start_meeting_calls].as_a
    calls.size.should be >= 1
    calls[0].as_i64.should eq bookings[:current_booking]["event_start"].as_i64
    bookings[:current_pending].as_bool.should eq false
    status[:prompted].should eq false
    status[:no_show].should eq false
  end

  it "checks in a late booking before the prompt window as well" do
    bookings, mailer = fresh_system({auto_cancel: true})

    # 3 minutes into the slot, more than the 1 minute threshold
    bookings[:current_booking] = build_booking("evt-walk-up-early", 3.minutes, created: Time.utc)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should be >= 1
  end

  it "checks in a late booking in prompt mode too" do
    bookings, mailer = fresh_system({auto_cancel: false})

    bookings[:current_booking] = build_booking("evt-walk-up-prompt", 12.minutes, created: Time.utc)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:start_meeting_calls].as_a.size.should be >= 1
    status[:prompted].should eq false
  end

  it "falls back to when the booking was first seen if the calendar has no created time" do
    bookings, mailer = fresh_system({auto_cancel: true})

    bookings[:current_booking] = build_booking("evt-walk-up-no-created", 12.minutes)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    bookings[:start_meeting_calls].as_a.size.should be >= 1
  end

  it "treats a booking made within a minute of its start as a regular booking" do
    bookings, mailer = fresh_system({auto_cancel: true})

    # booked 30 seconds after the slot started (below the 1 minute threshold)
    bookings[:current_booking] = build_booking("evt-on-time", 12.minutes, created: 11.minutes.ago - 30.seconds)
    bookings[:current_pending] = true
    settle

    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 1
    status[:no_show].should eq true
  end

  it "uses 10% of prompt_after as the threshold for longer prompt windows" do
    # prompt_after 30 minutes => threshold 3 minutes
    bookings, _mailer = fresh_system({auto_cancel: true, prompt_after: 30})

    # booked 2 minutes after the start, under the threshold, no action yet
    bookings[:current_booking] = build_booking("evt-30-under", 12.minutes, created: 10.minutes.ago)
    bookings[:current_pending] = true
    settle

    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 0
    status[:prompted].should eq false

    # booked 4 minutes after the start, over the threshold, checked in
    bookings[:current_booking] = build_booking("evt-30-over", 12.minutes, created: 8.minutes.ago)
    settle

    bookings[:start_meeting_calls].as_a.size.should be >= 1
    bookings[:end_meeting_calls].as_a.size.should eq 0
  end

  it "still auto cancels a pre-booked meeting when prompt_after is longer" do
    bookings, mailer = fresh_system({auto_cancel: true, prompt_after: 30})

    bookings[:current_booking] = build_booking("evt-30-cancel", 35.minutes, created: 2.hours.ago)
    bookings[:current_pending] = true
    settle

    mailer[:sent].as_i.should eq 0
    bookings[:start_meeting_calls].as_a.size.should eq 0
    bookings[:end_meeting_calls].as_a.size.should eq 1
  end

  it "exposes the template fields" do
    fields = exec(:template_fields).get.as_a
    fields.size.should eq 1
    fields[0]["trigger"].as_a.map(&.as_s).should eq ["bookings", "check_in_prompt"]
    fields[0]["fields"].as_a.map(&.["name"].as_s).should contain "jwt"
  end
end

# :nodoc:
# Mocks the parts of Place::Bookings the check-in helper depends on
class BookingsMock < DriverSpecs::MockDriver
  def on_load
    self[:current_booking] = nil
    self[:current_pending] = false
    self[:sensor_stale] = false
    self[:presence] = false

    # what `people_present?` returns, nil == no sensor data
    self[:people_present] = 0.0

    self[:start_meeting_calls] = [] of Int64
    self[:end_meeting_calls] = [] of String
    self[:last_booking_started] = nil
  end

  # 1.0 == people present, 0.0 == nobody present, nil == unknown
  def people_present? : Float64?
    value = self[:people_present]?
    value.try { |data| data.as_f? || data.as_i?.try(&.to_f) }
  end

  # we no longer accept user specified values
  def start_meeting(meeting_start_time : Int64) : Nil
    calls = self[:start_meeting_calls].as_a
    self[:start_meeting_calls] = calls + [JSON::Any.new(meeting_start_time)]
    checkin
  end

  def checkin : Nil
    if booking = self[:current_booking]?
      self[:last_booking_started] = booking["event_start"]?
    end
    self[:current_pending] = false
  end

  # the real driver declines the event and re-polls, we just record the call
  def end_meeting(meeting_start_time : Int64, notify : Bool = true, comment : String = "cancelled at booking panel") : Nil
    calls = self[:end_meeting_calls].as_a
    self[:end_meeting_calls] = calls + [JSON.parse({
      meeting_start_time: meeting_start_time,
      notify:             notify,
      comment:            comment,
    }.to_json)]
  end
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  def on_load
    self[:sent] = 0
    self[:template] = nil
    self[:to] = nil
    self[:cc] = nil
    self[:reply_to] = nil
    self[:args] = nil
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
    self[:sent] = self[:sent].as_i + 1
    self[:template] = template
    self[:to] = to
    self[:cc] = cc
    self[:reply_to] = reply_to
    self[:args] = args
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_user(email : String)
    {name: "Host", email: email}
  end
end
