require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
  def on_load
    self[:rejected] = 0
  end

  def reject(booking_id : String | Int64, utm_source : String? = nil)
    self[:rejected] = self[:rejected].as_i + 1
  end

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
    bookings = [
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
        booking_start:   (Time.utc).to_unix,
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
        asset_id:        "desk_003",
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
    ]

    JSON.parse(bookings.to_json)
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
          start_time:  (Time.utc - 4.hours).hour,
          end_time:    (Time.utc + 4.hours).hour,
          location:    "wfh",
        }
      end,
      work_overrides: {
        "2024-02-15": {
          day_of_week: 4,
          start_time:  9,
          end_time:    17,
          location:    "wfo",
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
          start_time:  (Time.utc - 4.hours).hour,
          end_time:    (Time.utc + 4.hours).hour,
          location:    "wfo",
        }
      end,
      work_overrides: {
        "2024-02-15": {
          day_of_week: 4,
          start_time:  9,
          end_time:    17,
          location:    "wfo",
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

    case id
    when "user-wfh"
      JSON.parse(user_wfh.to_json)
      # when "user-aol"
      #   JSON.parse(user_wfh.to_json)
    when "user-wfo"
      JSON.parse(user_wfo.to_json)
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
  })

  resp = exec(:get_building_id).get
  resp.should eq "zone-1234"

  resp = exec(:enabled?).get
  resp.should eq true

  resp = exec(:get_pending_bookings).get
  resp.not_nil!.as_a.size.should eq 5

  resp = exec(:get_user_preferences?, "user-wfh").get
  resp.not_nil!.as_h.keys.should eq ["work_preferences", "work_overrides"]

  # Should only have 3 pending releases (ignore, notify, reject)
  resp = exec(:pending_release).get
  pending_release = resp.not_nil!.as_a.map(&.as_h["title"])
  pending_release.size.should eq 3
  pending_release.should eq ["ignore", "notify", "reject"]

  # Should only reject one booking (booking_id: 3, title: reject)
  resp = exec(:release_bookings).get
  resp.should eq [3]
  system(:StaffAPI_1)[:rejected].should eq 1

  # Don't try to reject bookings that have already been rejected
  resp = exec(:release_bookings).get
  resp.should eq [3]
  system(:StaffAPI_1)[:rejected].should eq 1

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

  # TODO: test work_overrides
end
