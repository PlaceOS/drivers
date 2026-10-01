require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
  getter metadata_shape : String = "legacy"
  getter failing_type : String? = nil
  getter asset_calls = 0
  getter type_calls = 0

  def configure(metadata_shape : String, failing_type : String? = nil)
    @metadata_shape = metadata_shape
    @failing_type = failing_type
  end

  def asset_categories(hidden : Bool? = nil)
    JSON.parse([
      {id: "category-desk", name: "_DESKS_", hidden: true},
      {id: "category-parking", name: "_PARKING_", hidden: true},
      {id: "category-parking-legacy", name: "_PARKING_SPACES_", hidden: true},
    ].to_json)
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    @type_calls += 1
    JSON.parse([
      {id: "type-desk", name: "_DESKS_", category_id: "category-desk"},
      {id: "type-parking", name: "_PARKING_SPACES_", category_id: "category-parking"},
      {id: "type-parking-duplicate", name: "_PARKING_SPACES_", category_id: "category-parking"},
      {id: "type-parking-legacy", name: "_PARKING_SPACES_", category_id: "category-parking-legacy"},
      {id: "type-parking-users", name: "_PARKING_USERS_", category_id: "category-parking"},
      {id: "type-locker", name: "_LOCKERS_", category_id: "category-desk"},
    ].select { |type| category_id.nil? || type[:category_id] == category_id }.to_json)
  end

  def assets(type_id : String? = nil, zone_id : String? = nil)
    @asset_calls += 1
    raise "assets unavailable" if type_id == failing_type
    ids = case type_id
          when "type-desk"              then ["asset-desk-1", "asset-desk-2"]
          when "type-parking"           then ["asset-park-1"]
          when "type-parking-duplicate" then ["asset-park-2"]
          when "type-parking-legacy"    then ["asset-park-3"]
          else                               ["unrelated-asset"]
          end
    ids = [] of String unless zone_id == "level-1" || zone_id == "level-2"
    JSON.parse(ids.map { |id| {id: id, identifier: "Name #{id}", name: nil, zone_id: zone_id, zones: [] of String} }.to_json)
  end

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

    return JSON.parse("{}") if metadata_shape == "missing"
    raise "metadata unavailable" if metadata_shape == "error"
    unless metadata_shape == "legacy"
      details = case metadata_shape
                when "migrated" then JSON.parse(%({"migrated":true,"migrated_at":1765438509624}))
                when "empty"    then JSON.parse("[]")
                when "null"     then JSON.parse("null")
                when "object"   then JSON.parse("{}")
                else                 JSON.parse(%(""))
                end
      return JSON.parse({key => {name: key, parent_id: id, details: details}}.to_json)
    end

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
             end
    if metadata_shape == "migrated"
      assets = type == "desk" ? ["asset-desk-1", "asset-desk-2"] : ["asset-park-1", "asset-park-2", "asset-park-3"]
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
    reply_to : String | Array(String) | Nil = nil,
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
    reply_to : String | Array(String) | Nil = nil,
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
    booking_type: "desk",
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

  api = system(:StaffAPI_1).as(StaffAPI)

  it "keeps legacy capacity lists metadata-only when Asset records also exist" do
    settings({booking_type: "desk", zones: ["level-1"]})
    exec(:get_asset_ids).get.should eq({"level-1" => ["desk-1", "desk-2"]})
    api.asset_calls.should eq 0
    api.type_calls.should eq 0
  end

  it "sends at-capacity mail for a migrated desk zone" do
    api.configure("migrated")
    settings({booking_type: "desk", zones: ["level-2"]})
    exec(:get_asset_ids).get.should eq({"level-2" => ["asset-desk-1", "asset-desk-2"]})
    exec(:check_capacity).get
    system(:Mailer_1)[:sent].should eq 2
  end

  it "includes duplicate parking types from current and legacy categories" do
    api.configure("migrated")
    settings({booking_type: "parking", zones: ["level-1"]})
    exec(:get_asset_ids).get.should eq({"level-1" => ["asset-park-1", "asset-park-2", "asset-park-3"]})
  end

  ["missing", "null", "object", "string", "error"].each do |shape|
    it "uses Asset records for #{shape} metadata" do
      api.configure(shape)
      settings({booking_type: "desk", zones: ["level-1"]})
      exec(:get_asset_ids).get.should eq({"level-1" => ["asset-desk-1", "asset-desk-2"]})
    end
  end

  it "keeps an empty metadata array as an empty capacity list" do
    api.configure("empty")
    settings({booking_type: "desk", zones: ["level-1"]})
    calls = api.asset_calls
    exec(:get_asset_ids).get.should eq({"level-1" => [] of String})
    api.asset_calls.should eq calls
  end

  it "caches Asset lists per zone and shares type discovery between zones" do
    api.configure("migrated")
    settings({booking_type: "parking", zones: ["level-1", "level-2"]})
    asset_calls = api.asset_calls
    type_calls = api.type_calls
    exec(:get_asset_ids).get
    exec(:get_asset_ids).get
    api.asset_calls.should eq asset_calls + 6
    api.type_calls.should eq type_calls + 1
  end

  it "expires the Asset list and type caches using asset_cache_timeout" do
    api.configure("migrated")
    settings({booking_type: "desk", zones: ["level-1"], asset_cache_timeout: 0})
    asset_calls = api.asset_calls
    type_calls = api.type_calls
    2.times { exec(:get_asset_ids).get }
    api.asset_calls.should eq asset_calls + 2
    api.type_calls.should eq type_calls + 2
  end

  it "retains available assets when one duplicate type cannot be queried" do
    api.configure("migrated", "type-parking-duplicate")
    settings({booking_type: "parking", zones: ["level-1"]})
    exec(:get_asset_ids).get.should eq({"level-1" => ["asset-park-1", "asset-park-3"]})
    api.configure("migrated")
  end
end
