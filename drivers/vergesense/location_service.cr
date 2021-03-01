module Vergesense; end

require "json"
require "oauth2"
require "placeos-driver/interface/locatable"
require "./models"

class Vergesense::LocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "Vergesense Location Service"
  generic_name :VergesenseLocationService
  description %(collects desk booking data from the staff API and overlays Vergesense data for visualising on a map)

  accessor area_manager : AreaManagement_1
  accessor vergesense : Vergesense_1

  default_settings({
    floor_mappings: {
      "vergesense_building_id-floor_id": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  @zone_filter : Array(String) = [] of String
  @building_mappings : Hash(String, String?) = {} of String => String?

  def on_load
    on_update
  end

  def on_update
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @zone_filter = @floor_mappings.values.map do |z|
      level = z[:level_id]
      @building_mappings[level] = z[:building_id]
      level
    end

    bind_floor_status
  end

  # ===================================
  # Bindings into Vergesense data
  # ===================================
  protected def bind_floor_status
    subscriptions.clear

    @floor_mappings.each do |floor_id, details|
      zone_id = details[:level_id]
      vergesense.subscribe(floor_id) do |_sub, payload|
        level_state_change(zone_id, Floor.from_json(payload))
      end
    end
  end

  # Zone_id => Floor
  @occupancy_mappings : Hash(String, Floor) = {} of String => Floor

  protected def level_state_change(zone_id, floor)
    @occupancy_mappings[zone_id] = floor
    area_manager.update_available({zone_id})
  rescue error
    logger.error(exception: error) { "error updating level #{zone_id} space changes" }
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "sensor incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "sensor incapable of tracking #{email} or #{username}" }
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "sensor incapable of tracking #{mac_address}" }
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Nil unless @zone_filter.includes?(zone_id)

    floor = @occupancy_mappings[zone_id]?
    return [] of Nil unless floor

    floor.spaces.compact_map do |space|
      loc_type = space.space_type == "desk" ? "desk" : "area"
      next if location.presence && location != loc_type

      people_count = space.people.try(&.count)

      if people_count && people_count > 0
        {
          location:    loc_type,
          at_location: people_count,
          map_id:      space.name,
          level:       zone_id,
          building:    @building_mappings[zone_id]?,
          capacity:    space.capacity,

          vergesense_space_id:   space.space_ref_id,
          vergesense_space_type: space.space_type,
        }
      end
    end
  end
end
