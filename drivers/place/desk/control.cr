require "placeos-driver"
require "placeos-driver/interface/desk_control"
require "placeos"
require "json"
require "../desk_source"

class Place::Desk::Control < PlaceOS::Driver
  include Place::DeskSource

  descriptive_name "PlaceOS Desk Control"
  generic_name :DeskControl
  description %(helper for handling desk control)

  default_settings({
    desk_id_key: "id",

    # read desks from `_DESKS_` assets instead of the `desks` zone metadata
    use_desk_assets: false,
  })

  accessor area_manager : AreaManagement_1
  accessor staff_api : StaffAPI_1

  def on_load
    # cache desk ids periodically
    schedule.every(1.hour) { @desk_ids = nil }
    on_update
  end

  def on_update
    @desk_id_key = setting?(String, :desk_id_key) || "id"
    @desk_ids = nil
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

  # desk id => the id configured under `desk_id_key`
  getter desk_ids : Hash(String, String) do
    key = desk_id_key
    desks = {} of String => String

    level_buildings.values.uniq!.each do |building_id|
      building_desks(building_id).each_value do |level_desks|
        level_desks.each do |desk|
          if mapped_id = desk.value(key).try(&.as_s?)
            desks[desk.id] = mapped_id
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
