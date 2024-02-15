require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
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
        user_id:         "user-wYLBwmC7GFbupt",
        user_email:      "user_one@example.com",
        user_name:       "User One",
        asset_id:        "desk_001",
        zones:           ["zone_one"],
        booking_type:    "desk",
        booking_start:   (Time.utc + 1.hour).to_unix,
        booking_end:     (Time.utc + 2.hours).to_unix,
        timezone:        "Australia/Darwin",
        title:           "Booking",
        description:     "desk one",
        checked_in:      false,
        rejected:        false,
        approved:        true,
        booked_by_id:    "user-wYLBwmC7GFbupt",
        booked_by_email: "user_one@example.com",
        booked_by_name:  "User One",
        process_state:   "approved",
        last_changed:    Time.utc.to_unix,
        created:         Time.utc.to_unix,
      },
    ]

    JSON.parse(bookings.to_json)
  end

  def user(id : String)
    user = {
      created_at:   Time.utc.to_unix,
      id:           id,
      email_digest: "5acf9dfa861dbeabde3dc0a2148a0f2b",
      name:         "User One",
      first_name:   "User",
      last_name:    "One",
      groups:       [] of String,
      country:      "Australia",
      building:     "",
      image:        "",
      authority_id: "authority-wYLBwmC7GFbupt",
      deleted:      false,
      department:   "",
      work_preferences: [
        {
          day_of_week: 0,
          start_time: 9,
          end_time: 17,
          location: "wfo",
        },
        {
          day_of_week: 1,
          start_time: 9,
          end_time: 17,
          location: "wfo",
        },
        {
          day_of_week: 2,
          start_time: 9,
          end_time: 17,
          location: "wfh",
        },
        {
          day_of_week: 3,
          start_time: 9,
          end_time: 17,
          location: "wfh",
        },
        {
          day_of_week: 4,
          start_time: 9,
          end_time: 17,
          location: "wfh",
        },
        {
          day_of_week: 5,
          start_time: 9,
          end_time: 17,
          location: "wfh",
        },
        {
          day_of_week: 6,
          start_time: 9,
          end_time: 17,
          location: "wfo",
        },
      ],
      work_overrides: {
        "2024-02-15": {
          day_of_week: 4,
          start_time: 9,
          end_time: 17,
          location: "wfo",
        }
      },
      sys_admin:    false,
      support:      false,
      email:        "user_one@example.com",
      phone:        "",
      ui_theme:     "light",
      login_name:   "",
      staff_id:     "",
      card_number:  "",
    }
    
    JSON.parse(user.to_json)
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

DriverSpecs.mock_driver "Place::StaffAPI" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
  })

  _resp = exec(:pending_release).get
  # _resp = exec(:get_user_preferences, "user-wYLBwmC7GFbupt").get

  # system(:Mailer_1)[:sent].should eq 1
end
