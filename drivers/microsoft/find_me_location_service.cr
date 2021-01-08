module Microsoft; end

require "json"
require "oauth2"
require "s2_cells"
require "placeos-driver/interface/locatable"
require "./find_me_models"

class Microsoft::FindMeLocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "FindMe Location Service"
  generic_name :FindMeLocationService
  description %(collects desk usage and wireless locations for visualising on a map)

  accessor findme : FindMe_1

  default_settings({
    map_id_prefix: "table-",

    floor_mappings: {
      "zone-id": {
        building: "SYDNEY",
        level:    "L14",
      },
    },

    building_zone: "zone-building",
    s2_level:      21,
  })

  @building_zone : String = ""
  @floor_mappings : Hash(String, NamedTuple(building: String, level: String)) = {} of String => NamedTuple(building: String, level: String)
  @zone_filter : Array(String) = [] of String
  @map_id_prefix : String = "table-"
  @s2_level : Int32 = 21

  def on_load
    on_update
  end

  def on_update
    @map_id_prefix = setting?(String, :map_id_prefix).presence || "table-"

    @building_zone = setting(String, :building_zone)
    @floor_mappings = setting(Hash(String, NamedTuple(building: String, level: String)), :floor_mappings)
    @zone_filter = @floor_mappings.keys
    @s2_level = setting?(Int32, :s2_level) || 21
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }

    locations_raw = findme.user_details(username).get.to_json
    locations = Array(Microsoft::Location).from_json locations_raw

    locations = locations.compact_map do |location|
      coords = location.coordinates
      next unless coords

      level = findme_building = findme_level = ""
      @floor_mappings.each do |zone, details|
        findme_building = details[:building]
        findme_level = details[:level]

        if findme_building == coords.building && findme_level == coords.level
          level = zone
          break
        end
      end

      next if level.empty?

      build_location_response(location, level, findme_building, findme_level)
    end

    locations
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }

    active_users_raw = findme.user_details(username || email).get.to_json
    active_users = Array(Microsoft::Location).from_json active_users_raw

    found = [] of String
    if user_details = active_users[0]?
      found << user_details.username
    end
    found
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "searching for owner of #{mac_address}" }

    active_users_raw = findme.user_details(mac_address).get.to_json
    active_users = Array(Microsoft::Location).from_json active_users_raw

    if user_details = active_users[0]?
      {
        location:    user_details.located_using == "FixedLocation" ? "desk" : "wireless",
        assigned_to: user_details.user_data.not_nil!.email_address || "",
        mac_address: mac_address,
      }
    end
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    return [] of Nil unless @zone_filter.includes?(zone_id)

    findme_details = @floor_mappings[zone_id]?
    return [] of Nil unless findme_details

    findme_building = findme_details[:building]
    findme_level = findme_details[:level]
    active_users_raw = findme.users_on(findme_building, findme_level).get.to_json
    active_users = Array(Microsoft::Location).from_json active_users_raw

    locations = active_users.compact_map do |loc|
      build_location_response(loc, zone_id, findme_building, findme_level, location)
    end

    locations
  end

  protected def build_location_response(location, zone_id, findme_building, findme_level, loc_type = nil)
    case location.located_using
    when "FixedLocation"
      return if loc_type.presence && loc_type != "desk"

      location_id = "#{@map_id_prefix}#{location.location_id}"

      loc = {
        location:    :desk,
        at_location: 1,
        map_id:      location_id,
        level:       zone_id,
        building:    @building_zone,
        mac:         location.username,
        last_seen:   location.last_update.to_unix,
        capacity:    1,

        findme_building: findme_building,
        findme_level:    findme_level,
        findme_status:   location.status,
        findme_type:     location.type,
      }

      loc
    when "WiFi"
      return if loc_type.presence && loc_type != "wireless"

      coordinates = location.coordinates
      return unless coordinates

      if gps = location.gps
        lat = gps.latitude
        lon = gps.longitude
      end

      # Based on the confidence % and a max variance of 20m
      variance = 20 - (20 * (location.confidence / 100))

      loc = {
        location:         :wireless,
        coordinates_from: "top-left",
        x:                coordinates.x,
        y:                coordinates.y,
        # x,y coordinates are % based so map width and height are out of 100
        map_width: 100,
        # by not returning map height, it indicates that a relative height should be calculated
        # map_height:       100,
        lon:        lon,
        lat:        lat,
        s2_cell_id: lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,

        mac:      location.username,
        variance: variance,

        last_seen: location.last_update.to_unix,
        level:     zone_id,
        building:  @building_zone,

        findme_building: findme_building,
        findme_level:    findme_level,
        findme_status:   location.status,
        findme_type:     location.type,
      }
    else
      logger.info { "unexpected location type #{location.located_using}" }
      nil
    end
  end
end
