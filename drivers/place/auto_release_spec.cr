require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
  def on_load
    self[:rejected] = 0
  end

  def reject(booking_id : String | Int64, utm_source : String? = nil)
    self[:rejected] = self[:rejected].as_i + 1
  end

  # Using a constant for bookings to ensure the times don't change during tests
  BOOKINGS = [
    {
      id:              1,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_001",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc + 1.hour).to_unix,
      booking_end:     (Time.utc + 2.hours).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              2,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_002",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc + 5.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "notify",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              3,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_003",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "reject",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              4,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_004",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc + 5.hours).to_unix,
      booking_end:     (Time.utc + 6.hours).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_after_hours",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              5,
      user_id:         "user-wfo",
      user_email:      "user_two@example.com",
      user_name:       "User Two",
      asset_id:        "desk_005",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_wfo",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfo",
      booked_by_email: "user_two@example.com",
      booked_by_name:  "User Two",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              6,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_006",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_last_minute_checkin",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              7,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_007",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_last_minute_schedule_change",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              8,
      user_id:         "user-wfh",
      user_email:      "user_one@example.com",
      user_name:       "User One",
      asset_id:        "desk_008",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 2.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "reject_on_start",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfh",
      booked_by_email: "user_one@example.com",
      booked_by_name:  "User One",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              9,
      user_id:         "user-aol",
      user_email:      "user_three@example.com",
      user_name:       "User Three",
      asset_id:        "desk_009",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "release_override_aol",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-aol",
      booked_by_email: "user_three@example.com",
      booked_by_name:  "User Three",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
    {
      id:              10,
      user_id:         "user-wfh-override",
      user_email:      "user_four@example.com",
      user_name:       "User Four",
      asset_id:        "desk_010",
      zones:           ["zone-1234"],
      booking_type:    "desk",
      booking_start:   (Time.utc - 11.minutes).to_unix,
      booking_end:     (Time.utc + 1.hour).to_unix,
      timezone:        "Australia/Darwin",
      title:           "ignore_override",
      description:     "",
      checked_in:      false,
      rejected:        false,
      approved:        true,
      booked_by_id:    "user-wfo-override",
      booked_by_email: "user_four@example.com",
      booked_by_name:  "User Four",
      process_state:   "approved",
      last_changed:    Time.utc.to_unix,
      created:         Time.utc.to_unix,
    },
  ]

  NOW         = Time.local(location: Time::Location.load("Australia/Sydney"))
  DATE        = NOW.to_s(format: "%F")
  DAY_OF_WEEK = NOW.day_of_week.value == 0 ? 7 : NOW.day_of_week.value

  def query_bookings(
    type : String? = nil,
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
    JSON.parse(BOOKINGS.to_json)
  end

  def get_booking(booking_id : String | Int64)
    booking = query_bookings.as_a.find { |b| b.as_h["id"] == booking_id }
    return unless booking

    case booking_id
    when 6
      booking.as_h["checked_in"] = JSON.parse(true.to_json)
    when 7
      booking.as_h["booking_start"] = JSON.parse((Time.utc + 1.hour).to_unix.to_json)
      booking.as_h["booking_end"] = JSON.parse((Time.utc + 2.hours).to_unix.to_json)
    end
    booking
  end

  def user(id : String)
    user_wfh = {
      created_at:       Time.utc.to_unix,
      id:               id,
      email_digest:     "not_real_digest",
      name:             "User One",
      first_name:       "User",
      last_name:        "One",
      groups:           [] of String,
      country:          "Australia",
      building:         "",
      image:            "",
      authority_id:     "authority-wfh",
      deleted:          false,
      department:       "",
      work_preferences: 7.times.map do |i|
        {
          day_of_week: i,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "wfh",
            },
          ],
        }
      end,
      work_overrides: {
        "2024-02-15": {
          day_of_week: 4,
          blocks:      [
            {
              start_time: 9,
              end_time:   17,
              location:   "wfo",
            },
          ],
        },
      },
      sys_admin:   false,
      support:     false,
      email:       "user_one@example.com",
      phone:       "",
      ui_theme:    "light",
      login_name:  "",
      staff_id:    "",
      card_number: "",
    }

    user_wfo = {
      created_at:       Time.utc.to_unix,
      id:               id,
      email_digest:     "not_real_digest",
      name:             "User Two",
      first_name:       "User",
      last_name:        "Two",
      groups:           [] of String,
      country:          "Australia",
      building:         "",
      image:            "",
      authority_id:     "authority-wfo",
      deleted:          false,
      department:       "",
      work_preferences: 7.times.map do |i|
        {
          day_of_week: i,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "wfo",
            },
          ],
        }
      end,
      work_overrides: {
        "2024-02-15": {
          day_of_week: 4,
          blocks:      [
            {
              start_time: 9,
              end_time:   17,
              location:   "wfo",
            },
          ],
        },
      },
      sys_admin:   false,
      support:     false,
      email:       "user_two@example.com",
      phone:       "",
      ui_theme:    "light",
      login_name:  "",
      staff_id:    "",
      card_number: "",
    }

    user_aol = {
      created_at:       Time.utc.to_unix,
      id:               id,
      email_digest:     "not_real_digest",
      name:             "User Three",
      first_name:       "User",
      last_name:        "Three",
      groups:           [] of String,
      country:          "Australia",
      building:         "",
      image:            "",
      authority_id:     "authority-aol",
      deleted:          false,
      department:       "",
      work_preferences: 7.times.map do |i|
        {
          day_of_week: i,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "wfo",
            },
          ],
        }
      end,
      work_overrides: {
        DATE => {
          day_of_week: DAY_OF_WEEK,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "aol",
            },
          ],
        },
      },
      sys_admin:   false,
      support:     false,
      email:       "user_three@example.com",
      phone:       "",
      ui_theme:    "light",
      login_name:  "",
      staff_id:    "",
      card_number: "",
    }

    user_wfh_override = {
      created_at:       Time.utc.to_unix,
      id:               id,
      email_digest:     "not_real_digest",
      name:             "User Four",
      first_name:       "User",
      last_name:        "Four",
      groups:           [] of String,
      country:          "Australia",
      building:         "",
      image:            "",
      authority_id:     "authority-wfo-override",
      deleted:          false,
      department:       "",
      work_preferences: 7.times.map do |i|
        {
          day_of_week: i,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "wfh",
            },
          ],
        }
      end,
      work_overrides: {
        DATE => {
          day_of_week: DAY_OF_WEEK,
          blocks:      [
            {
              start_time: (Time.local(location: Time::Location.load("Australia/Sydney")) - 4.hours).hour,
              end_time:   (Time.local(location: Time::Location.load("Australia/Sydney")) + 4.hours).hour,
              location:   "wfo",
            },
          ],
        },
      },
      sys_admin:   false,
      support:     false,
      email:       "user_four@example.com",
      phone:       "",
      ui_theme:    "light",
      login_name:  "",
      staff_id:    "",
      card_number: "",
    }

    case id
    when "user-wfh"
      JSON.parse(user_wfh.to_json)
    when "user-wfo"
      JSON.parse(user_wfo.to_json)
    when "user-aol"
      JSON.parse(user_aol.to_json)
    when "user-wfh-override"
      JSON.parse(user_wfh_override.to_json)
    else
      JSON.parse(user_wfh.to_json)
    end
  end

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    zones = [
      {
        created_at:   1660537814,
        updated_at:   1681800971,
        id:           "zone-1234",
        name:         "Test Zone",
        display_name: "Test Zone",
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

    JSON.parse(zones.to_json)
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

DriverSpecs.mock_driver "Place::AutoRelease" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
  })

  settings({
    time_window_hours: 8,
    auto_release:      {
      time_before: 10,
      time_after:  10,
      resources:   ["desk"],
    },
    release_locations: ["wfh", "aol"],
  })

  resp = exec(:get_building_zone?).get
  resp.not_nil!.as_h["id"].should eq "zone-1234"

  resp = exec(:get_pending_bookings).get
  resp.not_nil!.as_a.size.should eq 10

  resp = exec(:get_user_preferences?, "user-wfh").get
  resp.not_nil!.as_h.keys.should eq ["work_preferences", "work_overrides"]

  # this also tests #skip_release?
  resp = exec(:pending_release).get
  pending_release = resp.not_nil!.as_a.map(&.as_h["title"])
  pending_release.size.should eq 7
  pending_release.should eq [
    "ignore",
    "notify",
    "reject",
    "ignore_last_minute_checkin",
    "ignore_last_minute_schedule_change",
    "reject_on_start",
    "release_override_aol",
  ]

  # Start of tests for: #release_bookings
  #######################################

  settings({
    time_window_hours: 8,
    auto_release:      {
      time_before: 10,
      time_after:  10,
      resources:   ["desk"],
    },
    release_locations: ["wfh", "aol"],
  })

  # Should reject 2 bookings
  # booking_id: 3, title: reject
  # booking_id: 9, title: release_override_aol
  resp = exec(:release_bookings).get
  resp.should eq [3, 9]
  system(:StaffAPI_1)[:rejected].should eq 2

  # Don't try to reject bookings that have already been rejected
  resp = exec(:release_bookings).get
  resp.should eq [3, 9]
  system(:StaffAPI_1)[:rejected].should eq 2

  # Reject bookings immidiatly on start
  settings({
    time_window_hours: 8,
    auto_release:      {
      time_before: 10,
      time_after:  0,
      resources:   ["desk"],
    },
    release_locations: ["wfh", "aol"],
  })

  # Should reject two bookings
  # booking_id: [3, 9, 8], title: ["reject", "release_override_aol", "reject_on_start"]
  resp = exec(:release_bookings).get
  resp.should eq [3, 9, 8]
  system(:StaffAPI_1)[:rejected].should eq 3

  #####################################
  # End of tests for: #release_bookings

  # Start of tests for: #send_release_emails
  ##########################################

  settings({
    time_window_hours: 8,
    auto_release:      {
      time_before: 10,
      time_after:  10,
      resources:   ["desk"],
    },
  })

  # Send email once booking is past the time_before window,
  # but before the time_after window
  # (booking_id: 2, title: notify)
  resp = exec(:send_release_emails).get
  resp.should eq [2]
  system(:Mailer_1)[:sent].should eq 1

  # Spam protection, should not send email again
  resp = exec(:send_release_emails).get
  resp.should eq [2]
  system(:Mailer_1)[:sent].should eq 1

  ########################################
  # End of tests for: #send_release_emails

  # Start of tests for: #in_preference_hours?
  ###########################################

  # normal work hours, event in range
  # start at 8am, end at 4pm, event at 3pm
  resp = exec(:in_preference_hours?, 8.0, 16.0, 15.0).get
  resp.should eq true

  # normal work hours, event out of range (after)
  # start at 8am, end at 4pm, event at 5pm
  resp = exec(:in_preference_hours?, 8.0, 16.0, 17.0).get
  resp.should eq nil

  # normal work hours, event out of range (before)
  # start at 8am, end at 4pm, event at 6am
  resp = exec(:in_preference_hours?, 8.0, 16.0, 6.0).get
  resp.should eq nil

  # work hours crosses midnight, event in range
  # start at 10pm, end at 6am, event at 3am
  resp = exec(:in_preference_hours?, 22.0, 6.0, 3.0).get
  resp.should eq true

  # work hours crosses midnight, event out of range (after)
  # start at 10pm, end at 6am, event at 7am
  resp = exec(:in_preference_hours?, 22.0, 6.0, 7.0).get
  resp.should eq nil

  # work hours crosses midnight, event out of range (before)
  # start at 10pm, end at 6am, event at 8pm
  resp = exec(:in_preference_hours?, 22.0, 6.0, 20.0).get
  resp.should eq nil

  #########################################
  # End of tests for: #in_preference_hours?

  # Start of tests for: #enabled?
  ###############################

  # disabled wehn both time_before and time_after are 0
  settings({
    auto_release: {
      time_before: 0,
      time_after:  0,
      resources:   ["desk"],
    },
  })
  resp = exec(:enabled?).get
  resp.should eq nil
  # enabled when time_before is set and time_after is 0
  settings({
    auto_release: {
      time_before: 10,
      time_after:  0,
      resources:   ["desk"],
    },
  })
  resp = exec(:enabled?).get
  resp.should eq true
  # enabled when time_before is 0 and time_after is set
  settings({
    auto_release: {
      time_before: 0,
      time_after:  10,
      resources:   ["desk"],
    },
  })
  resp = exec(:enabled?).get
  resp.should eq true
  # enabled when both time_before and time_after are set
  settings({
    auto_release: {
      time_before: 10,
      time_after:  10,
      resources:   ["desk"],
    },
  })
  # disabled when resources is empty
  resp = exec(:enabled?).get
  resp.should eq true
  settings({
    auto_release: {
      time_before: 10,
      time_after:  10,
      resources:   [] of String,
    },
  })
  resp = exec(:enabled?).get
  resp.should eq nil

  #############################
  # End of tests for: #enabled?
end
