require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
  ZONES = [
    {
      created_at:   1660537814,
      updated_at:   1681800971,
      id:           "level-1",
      name:         "Level 1",
      display_name: "Level 1",
      location:     "",
      description:  "",
      code:         "",
      type:         "",
      count:        0,
      capacity:     0,
      map_id:       "",
      tags:         [
        "level",
      ],
      triggers:  [] of String,
      parent_id: "zone-0000",
      timezone:  "Australia/Sydney",
    },
    {
      created_at:   1660537814,
      updated_at:   1681800971,
      id:           "level-2",
      name:         "Level 2",
      display_name: "Level 2",
      location:     "",
      description:  "",
      code:         "",
      type:         "",
      count:        0,
      capacity:     0,
      map_id:       "",
      tags:         [
        "level",
      ],
      triggers:  [] of String,
      parent_id: "zone-0000",
      timezone:  "Australia/Sydney",
    },
  ]

  def zone(zone_id : String)
    zones = ZONES.select { |z| z["id"] == zone_id }
    JSON.parse(zones.to_json)
  end

  def metadata(id : String, key : String? = nil)
    zone = ZONES.find! { |z| z["id"] == id }
    key = key.not_nil!

    details = case key
              when "desks"
                [
                  {
                    "id":       "desk-1",
                    "name":     "Desk 1",
                    "images":   [] of String,
                    "bookable": true,
                    "features": [] of String,
                  },
                  {
                    "id":       "desk-2",
                    "name":     "Desk 2",
                    "images":   [] of String,
                    "bookable": true,
                    "features": [] of String,
                  },
                ]
              when "parking-spaces"
                [
                  {
                    "id":            "park-1",
                    "name":          "Bay 1",
                    "zone":          zone[:id],
                    "notes":         "",
                    "map_id":        "",
                    "zone_id":       zone[:id],
                    "assigned_to":   nil,
                    "map_rotation":  0,
                    "assigned_name": nil,
                    "assigned_user": nil,
                  },
                  {
                    "id":            "park-2",
                    "name":          "Bay 2",
                    "zone":          zone[:id],
                    "notes":         "",
                    "map_id":        "",
                    "zone_id":       zone[:id],
                    "assigned_to":   nil,
                    "map_rotation":  0,
                    "assigned_name": nil,
                    "assigned_user": nil,
                  },
                ]
              when "lockers"
                [
                  {
                    "id":   "locker-1",
                    "name": "L1-01",
                    "size": [
                      1,
                      3,
                    ],
                    "tags": [
                      "Base",
                    ],
                    "notes":    "",
                    "bank_id":  "bank-1",
                    "bookable": true,
                    "features": [] of String,
                    "position": [
                      0,
                      0,
                    ],
                    "accessible":    true,
                    "assigned_user": nil,
                  },
                  {
                    "id":   "locker-2",
                    "name": "L1-02",
                    "size": [
                      1,
                      3,
                    ],
                    "tags": [
                      "Base",
                    ],
                    "notes":    "",
                    "bank_id":  "bank-1",
                    "bookable": true,
                    "features": [] of String,
                    "position": [
                      1,
                      0,
                    ],
                    "accessible":    true,
                    "assigned_user": nil,
                  },
                ]
              end

    JSON.parse(
      {key => {
        name:           key,
        description:    "#{key} for zone #{id}",
        details:        details,
        parent_id:      zone[:parent_id],
        editors:        [] of String,
        modified_by_id: "user-1234",
      }}.to_json)
  end

  def booked(
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
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    include_booked_by : Bool? = nil,
    department : String? = nil,
    limit : Int32? = nil,
    offset : Int32? = nil,
    permission : String? = nil,
    extension_data : JSON::Any? = nil,
  )
    assets = case type
             when "desk"
               ["desk-1", "desk-2"]
             when "parking"
               ["park-1"]
             when "locker"
               ["locker-1", "locker-2"]
             end
    JSON.parse(assets.to_json)
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
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil
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
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil
  ) : Bool
    true
  end
end

DriverSpecs.mock_driver "Place::AtCapacityMailer" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
  })

  # Start of tests for: #get_booked_asset_ids
  ###########################################

  settings({
    booking_type: "parking",
    zones:        ["level-1"],
  })

  resp = exec(:get_booked_asset_ids).get
  resp.not_nil!.as_a.should eq ["park-1"]

  ###########################################
  # End of tests for: #get_booked_asset_ids

  # Start of tests for: #get_assets_from_metadata
  ###############################################

  settings({
    booking_type: "desk",
    zones:        ["level-1"],
  })

  resp = exec(:get_assets_from_metadata, "level-1").get
  resp.not_nil!.as_a.map(&.as_h["id"]).should eq ["desk-1", "desk-2"]

  settings({
    booking_type: "parking",
    zones:        ["level-1"],
  })

  resp = exec(:get_assets_from_metadata, "level-1").get
  resp.not_nil!.as_a.map(&.as_h["id"]).should eq ["park-1", "park-2"]

  settings({
    booking_type: "locker",
    zones:        ["level-1"],
  })

  resp = exec(:get_assets_from_metadata, "level-1").get
  resp.not_nil!.as_a.map(&.as_h["id"]).should eq ["locker-1", "locker-2"]

  ###############################################
  # End of tests for: #get_assets_from_metadata

  # Start of tests for: #get_asset_ids
  ####################################

  settings({
    booking_type: "desk",
    zones:        ["level-1"],
  })

  resp = exec(:get_asset_ids).get
  resp.not_nil!.as_h.should eq Hash{"level-1" => ["desk-1", "desk-2"]}

  ####################################
  # End of tests for: #get_asset_ids

  # Start of tests for: #check_capacity
  #####################################

  # Not fully booked
  settings({
    booking_type: "parking",
    zones:        ["level-1"],
  })
  _resp = exec(:get_asset_ids).get # asset_ids are cached

  resp = exec(:check_capacity).get
  system(:Mailer_1)[:sent].should eq 0

  #  Fully booked
  settings({
    booking_type: "locker",
    zones:        ["level-1"],
  })
  _resp = exec(:get_asset_ids).get # asset_ids are cached

  resp = exec(:check_capacity).get
  system(:Mailer_1)[:sent].should eq 1

  # spam protection
  resp = exec(:check_capacity).get
  system(:Mailer_1)[:sent].should eq 1

  #####################################
  # End of tests for: #check_capacity
end
