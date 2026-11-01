require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

DriverSpecs.mock_driver "Place::Parking::Approvals" do
  system({
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
    Mailer:           {MailerMock},
  })

  base_settings = {
    poll_rate:            60,
    car_license_ext:      "car_license",
    auto_approval_groups: [] of String,
    analytics_cron:       "0 0 1 1 *",
    time_zone:            "Australia/Sydney",
  }
  settings(base_settings)
  staff_api = system(:StaffAPI).as(StaffAPIMock)
  mailer = system(:Mailer).as(MailerMock)

  # ===================================================
  # desk metadata
  # ===================================================
  # alice has an assigned desk so works in the building and requires approval,
  # carl is visiting so is auto approved (and wait listed as there are no spaces)
  exec(:process_parking_bookings).get.should eq "parking allocated"
  exec(:assigned_desks).get.should eq ["alice@org.com"]
  staff_api.metadata_requests.should eq ["zone-building"]
  staff_api.states.should eq [{1_i64, "waiting_approval"}, {2_i64, "wait_list"}]
  mailer.sent.should eq [
    {"alice@org.com", "approval_required"},
    {"carl@org.com", "wait_list"},
  ]

  # ===================================================
  # desk assets
  # ===================================================
  staff_api.reset
  mailer.reset
  settings(base_settings.merge({use_desk_assets: true}))

  # carl is now assigned a desk asset and alice is not
  exec(:assigned_desks).get.should eq ["carl@org.com"]
  staff_api.asset_requests.should eq [nil, "page-2"]

  exec(:process_parking_bookings).get.should eq "parking allocated"
  staff_api.metadata_requests.should be_empty
  staff_api.states.should eq [{1_i64, "wait_list"}, {2_i64, "waiting_approval"}]
  mailer.sent.should eq [
    {"alice@org.com", "wait_list"},
    {"carl@org.com", "approval_required"},
  ]
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  getter metadata_requests : Array(String) = [] of String
  getter asset_requests : Array(String?) = [] of String?
  getter states : Array(Tuple(Int64, String)) = [] of Tuple(Int64, String)

  def reset
    @metadata_requests.clear
    @asset_requests.clear
    @states.clear
  end

  def zone(zone_id : String)
    {id: zone_id, name: "Building", tags: ["building"]}
  end

  def metadata_children(id : String, key : String? = nil)
    @metadata_requests << id
    [
      {zone: {id: "zone-level-1"}, metadata: {desks: {name: "desks", details: [
        {id: "desk-1", name: "Desk 1", assigned_to: "Alice@org.com"},
        {id: "desk-2", name: "Desk 2", assigned_to: ""},
      ]}}},
      {zone: {id: "zone-level-2"}, metadata: {desks: {name: "desks", details: [
        {id: "desk-3", name: "Desk 3"},
      ]}}},
    ]
  end

  def asset_categories(hidden : Bool? = nil)
    [{id: "category-parking", name: "_PARKING_", hidden: true}]
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [
      {id: "type-desk", name: "_DESKS_"},
      {id: "type-parking", name: "_PARKING_SPACES_", category_id: "category-parking"},
    ]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, order_id : String? = nil, barcode : String? = nil, serial_number : String? = nil, bookable : Bool? = nil, accessible : Bool? = nil, features : Array(String)? = nil, zones : Array(String)? = nil, limit : Int32 = 1000, next_page : String? = nil)
    # no parking spaces are available
    return [] of String unless type_id == "type-desk"
    raise "unexpected zones #{zones}" unless zones == ["zone-building"]
    @asset_requests << next_page

    if next_page
      [{id: "asset-3", identifier: "desk-3", zone_id: "zone-level-2", assigned_to: "Carl@org.com"}]
    else
      [
        {id: "asset-1", identifier: "desk-1", zone_id: "zone-level-1", next_page: "page-2"},
        {id: "asset-2", identifier: "desk-2", zone_id: "zone-level-1", assigned_to: ""},
      ]
    end
  end

  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    extension_data : JSON::Any? = nil,
    deleted : Bool? = nil,
    asset_id : String? = nil,
    limit : Int32? = nil,
  )
    # only active booking requests
    return [] of String unless approved.nil? && rejected.nil? && deleted.nil?

    now = Time.utc.to_unix
    {"alice", "carl"}.map_with_index(1) do |name, id|
      {
        id:              id,
        booking_type:    "parking",
        booking_start:   now + 1.hour.total_seconds.to_i64,
        booking_end:     now + 2.hours.total_seconds.to_i64,
        asset_id:        "unallocated-#{id}",
        asset_ids:       ["unallocated-#{id}"],
        user_id:         name,
        user_email:      "#{name}@org.com",
        user_name:       name,
        booked_by_name:  name,
        booked_by_email: "#{name}@org.com",
        zones:           ["zone-building"],
        created:         now + id,
      }
    end
  end

  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    @states << {booking_id.to_i64, state}
    true
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def building_id : String
    "zone-building"
  end

  # everyone has a meeting in the building
  def bookings_for(email : String)
    [{id: "event-1", host: email}]
  end
end

# :nodoc:
class MailerMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  getter sent : Array(Tuple(String, String)) = [] of Tuple(String, String)

  def reset
    @sent.clear
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
    @sent << {to.to_s, template[1]}
    true
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
  ) : Bool
    true
  end
end
