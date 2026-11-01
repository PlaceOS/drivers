require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

DriverSpecs.mock_driver "Place::BookingApprovalWorkflows" do
  system({
    StaffAPI: {StaffAPIMock},
    Mailer:   {MailerMock},
  })

  base_settings = {
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
  }
  settings(base_settings)

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
  sleep 1.second

  # the cancellation email's reply-to should be the person who created the booking
  system(:Mailer)[:template].should eq ["bookings", "cancelled"]
  system(:Mailer)[:to].should eq "user@org.com"
  system(:Mailer)[:reply_to].should eq "booker@org.com"

  # =============================================================
  # invalid desk bookings: user isn't in any of the desk's groups
  # =============================================================
  staff_api = system(:StaffAPI).as(StaffAPIMock)
  ending = now + 86400

  # {email, desk id, zone, booking id}
  invalid = ->(users : JSON::Any) { users.as_a.map { |user| user.as_a[0..3].map(&.raw) } }

  # metadata mode: desk-2 is for sales, desk-3 has no groups, desk-unknown isn't defined
  users = exec(:users_with_invalid_desk_bookings, "zone-1", ending).get.not_nil!
  invalid.call(users).should eq [["user@org.com", "desk-2", "zone-level-1", 11_i64]]
  staff_api.asset_calls.should eq 0

  # assets mode: bookings reference the Asset#id and groups come from place_groups
  staff_api.migrate_bookings
  settings(base_settings.merge({use_desk_assets: true}))
  users = exec(:users_with_invalid_desk_bookings, "zone-1", ending).get.not_nil!
  invalid.call(users).should eq [["user@org.com", "asset-2", "zone-level-1", 11_i64]]
  staff_api.asset_calls.should eq 2
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

  def get_groups(user_id : String)
    [{name: "Engineering"}]
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter use_asset_ids : Bool = false
  getter asset_calls : Int32 = 0

  # bookings reference the Asset#id once desks are migrated
  def migrate_bookings : Nil
    @use_asset_ids = true
  end

  def metadata_children(id : String, key : String? = nil)
    raise "unexpected building #{id}" unless id == "zone-1"
    [
      {
        zone:     {id: "zone-level-1"},
        metadata: {
          desks: {
            details: [
              {id: "desk-1", name: "Desk 1", groups: ["Engineering"]},
              {id: "desk-2", name: "Desk 2", groups: ["Sales"]},
              {id: "desk-3", name: "Desk 3", groups: [] of String},
            ],
          },
        },
      },
    ]
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-desk", name: "_DESKS_"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    @asset_calls += 1
    raise "unexpected asset query" unless type_id == "type-desk" && zones == ["zone-1"]
    if next_page == "page-2"
      [{id: "asset-3", identifier: "desk-3", zone_id: "zone-level-1", place_groups: [] of String}]
    else
      [
        {id: "asset-1", identifier: "desk-1", zone_id: "zone-level-1", place_groups: ["ENGINEERING"], next_page: "page-2"},
        {id: "asset-2", identifier: "desk-2", zone_id: "zone-level-1", place_groups: ["Sales"]},
      ]
    end
  end

  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    created_before : Int64? = nil,
  )
    now = Time.utc.to_unix
    desks = use_asset_ids ? {"asset-1", "asset-2", "asset-3", "desk-2"} : {"desk-1", "desk-2", "desk-3", "desk-unknown"}
    desks.map_with_index do |desk_id, index|
      {
        id:            10 + index,
        booking_type:  "desk",
        booking_start: now + 3600,
        booking_end:   now + 7200,
        asset_id:      desk_id,
        user_email:    "user@org.com",
        zones:         ["zone-1", "zone-level-1"],
      }
    end.to_a
  end
end
