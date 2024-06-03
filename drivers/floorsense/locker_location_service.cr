require "uri"
require "json"
require "oauth2"
require "placeos-driver"
require "placeos-driver/interface/locatable"
require "./models"

class Floorsense::LockerLocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "Floorsense Locker Location Service"
  generic_name :FloorsenseLockerLocationService
  description %(collects locker booking data from the staff API and overlays Floorsense data for visualising on a map)

  accessor floorsense : Floorsense_1

  default_settings({
    floor_mappings: {
      "planid": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
    include_bookings: false,
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  # Level zone => plan_id
  @zone_mappings : Hash(String, String) = {} of String => String
  # Level zone => building_zone
  @building_mappings : Hash(String, String?) = {} of String => String?

  @include_bookings : Bool = false

  # floorsense bus id => floorsense locker id
  @bus_id_to_locker_id : Hash(Int32, Int32) = {} of Int32 => Int32

  def on_load
    on_update
  end

  def on_update
    @include_bookings = setting?(Bool, :include_bookings) || false
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @floor_mappings.each do |plan_id, details|
      level = details[:level_id]
      @building_mappings[level] = details[:building_id]
      @zone_mappings[level] = plan_id
    end
  end

  def bus_id_to_locker_id(id : Int32)
    @bus_id_to_locker_id[id]?
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
    floor_mac = URI::Params.parse mac_address
    user = floorsense.at_location(floor_mac["cid"], floor_mac["key"]).get
    {
      location:    "locker",
      assigned_to: user["name"].as_s,
      mac_address: mac_address,
    }
  rescue
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Nil if location && location != "locker"

    controller_id = @zone_mappings[zone_id]?
    return [] of Nil unless controller_id

    building = @building_mappings[zone_id]?

    raw_lockers = floorsense.lockers(controller_id).get.to_json
    lockers = Array(LockerInfo).from_json(raw_lockers).compact_map do |locker|
      @bus_id_to_locker_id[locker.bus_id] = locker.locker_id

      if locker.reserved
        {
          location:    :locker,
          at_location: 1,
          map_id:      locker.key,
          level:       zone_id,
          building:    building,
          capacity:    1,

          # So we can look up who is at a desk at some point in the future
          mac: "cid=#{locker.controller_id}&key=#{locker.key}",

          floorsense_status:      locker.status,
          floorsense_locker_type: locker.type,
        }
      end
    end

    lockers
  end
end
