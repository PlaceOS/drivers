require "placeos-driver"
require "placeos-driver/interface/desk_control"
require "placeos"
require "json"

class Place::Desk::Control < PlaceOS::Driver
  descriptive_name "PlaceOS Desk Control"
  generic_name :DeskControl
  description %(helper for handling desk control)

  default_settings({
    desk_id_key: "id",
  })

  accessor area_manager : AreaManagement_1
  accessor staff_api : StaffAPI_1

  METADATA_KEY = "desks"

  def on_load
    # cache desk ids periodically
    schedule.every(1.hour) { @desk_ids = nil }
    on_update
  end

  def on_update
    @desk_id_key = setting?(String, :desk_id_key) || "id"
  end

  getter desk_id_key : String = "id"

  def desk_lookup(desk_id : String) : String
    # if it's not id, then there is a mapping to another id
    if desk_id_key != "id"
      mapped_id = desk_ids[desk_id]?
      raise "mapped id not found" unless mapped_id
      mapped_id
    else
      desk_id
    end
  end

  protected def desk_control
    system.implementing(PlaceOS::Driver::Interface::DeskControl)
  end

  # ===================================
  # Desk control functions
  # ===================================

  def set_desk_height(desk_key : String, desk_height : Int32)
    desk_key = desk_lookup(desk_key)
    desk_control.set_desk_height(desk_key, desk_height).get
  end

  def get_desk_height(desk_key : String)
    desk_control.get_desk_height(desk_key).get
  end

  def set_desk_power(desk_key : String, desk_power : Bool?)
    desk_key = desk_lookup(desk_key)
    desk_control.set_desk_power(desk_key, desk_power).get
  end

  def get_desk_power(desk_key : String)
    desk_control.get_desk_power(desk_key).get
  end

  # ===================================
  # Desk zone queries
  # ===================================

  struct DeskId
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : String
  end

  struct Details
    include JSON::Serializable

    property details : Array(DeskId)
  end

  alias Zone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, Details)
  alias ChildMetadata = Array(NamedTuple(zone: Zone, metadata: Metadata))

  getter desk_ids : Hash(String, String) do
    metadatas = level_buildings.values.uniq.map do |zone_id|
      ChildMetadata.from_json(staff_api.metadata_children(
        zone_id,
        METADATA_KEY
      ).get.to_json)
    end

    desks = {} of String => String
    key = desk_id_key

    metadatas.each do |metadata|
      metadata.each do |level|
        zone = level[:zone]
        if ids = level[:metadata][METADATA_KEY]?.try(&.details)
          ids.each do |desk_details|
            if mapped_id = desk_details.json_unmapped[key]?.try(&.as_s?)
              desks[desk_details.id] = mapped_id
            end
          end
        end
      end
    end

    desks
  end

  # level_zone_id => building_zone_id
  getter level_buildings : Hash(String, String) do
    hash = area_manager.level_buildings.get.as_h.transform_values(&.as_s)
    raise "level cache not loaded yet" unless hash.size > 0
    hash
  end
end
