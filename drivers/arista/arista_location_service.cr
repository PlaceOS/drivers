require "s2_cells"
require "./wireless_manager_models"
require "placeos-driver"
require "placeos-driver/interface/locatable"

class Arista::LocationService < PlaceOS::Driver
  include Interface::Locatable

  generic_name :AristaLocations
  descriptive_name "Arista Wireless Locations"
  description "Arista location service"

  default_settings({
    floorplan_mappings: {
      "arista_level_id" => {
        "building":   "zone-12345",
        "level":      "zone-123456",
        "level_name": "BUILDING - L1",
      },
    },
  })

  accessor arista : Arista_Wifi_1

  # map_ids => data
  @floorplan_mappings : Hash(Int64, Hash(String, String | Int32)) = Hash(Int64, Hash(String, String | Int32)).new

  @floorplan_sizes = {} of Int64 => Layout

  def on_update
    @floorplan_mappings = setting?(Hash(Int64, Hash(String, String | Int32)), :floorplan_mappings) || @floorplan_mappings

    # cleanup caches once a day
    schedule.cron("0 3 * * *") do
      @floorplan_sizes = {} of Int64 => Layout
    end
  end

  def cached_layout(for_location : Int64) : Layout
    @floorplan_sizes[for_location]? || Layout.from_json(arista.layout(for_location).get.to_json)
  end

  def get_floorplan_size(for_location : Int64)
    layout = cached_layout(for_location)
    {layout.width, layout.length}
  rescue error
    logger.warn(exception: error) { "error obtaining floorplan size for location #{for_location}" }
    {50, 50}
  end

  # ============================
  # Location Services Interface:
  # ============================

  # array of devices and their x, y coordinates, that are associated with this user
  def locate_user(email : String? = nil, username : String? = nil)
    client = ClientDetails?.from_json arista.locate(email.presence || username.presence.as(String)).get.to_json
    return nil unless client

    location_id = client.device.location.id
    mappings = @floorplan_mappings[location_id]?
    return nil unless mappings

    building = mappings["building"]?.as(String?)
    level = mappings["level"]?.as(String?)

    map_width, map_height = get_floorplan_size(location_id)

    if coords = client.position.coordinates
      x = coords.x
      y = coords.y
      variance = 2
    else
      # middle of level + radius of level
      x = map_width // 2
      y = map_height // 2
      variance = map_width
    end

    [
      {
        location:         :wireless,
        coordinates_from: "top-left",
        x:                x,
        y:                y,
        # not sure if we can get geo coordinates...
        # lon:              lon,
        # lat:              lat,
        # s2_cell_id:       lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
        mac:        format_mac(client.device.macaddress),
        variance:   variance,
        last_seen:  Time.utc.to_unix,
        map_width:  map_width,
        map_height: map_height,
        os:         client.device.os,
        ssid:       client.device.ssid,
        building:   building,
        level:      level,
      },
    ]
  end

  # return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    arista.macs_assigned_to(username.presence || email.presence.as(String)).get.as_a.map &.as_s
  end

  # return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String) : OwnershipMAC?
    lookup = format_mac(mac_address)
    client = ClientDetails?.from_json arista.ownership_of(lookup).get.to_json
    return nil unless client

    if user = client.device.username
      {
        location:    "wireless",
        assigned_to: user,
        mac_address: lookup,
      }
    end
  end

  # array of devices and their x, y coordinates
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "looking up device locations in #{zone_id}" }
    return [] of String if location.presence && location != "wireless"

    # Find the floors associated with the provided zone id
    maps = [] of Int64
    @floorplan_mappings.each do |map_id, data|
      maps << map_id if data.values.includes?(zone_id)
    end
    logger.debug { "found matching arista floors: #{maps}" }
    return [] of String if maps.empty?

    # Find the devices that are on the matching floors
    all_devices = maps.flat_map do |map_id|
      clients = arista.status?(Array(ClientDetails), "location_#{map_id}") || [] of ClientDetails

      mappings = @floorplan_mappings[map_id]
      building = mappings["building"]?.as(String?)
      level = mappings["level"]?.as(String?)
      map_width, map_height = get_floorplan_size(map_id)

      time = Time.utc.to_unix

      clients.compact_map do |client|
        if coords = client.position.coordinates
          x = coords.x
          y = coords.y
          variance = 2
        else
          # middle of level + radius of level
          x = map_width // 2
          y = map_height // 2
          variance = map_width
        end

        {
          location:         :wireless,
          coordinates_from: "top-left",
          x:                x,
          y:                y,
          # not sure if we can get geo coordinates...
          # lon:              lon,
          # lat:              lat,
          # s2_cell_id:       lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
          mac:        format_mac(client.device.macaddress),
          variance:   variance,
          last_seen:  time,
          map_width:  map_width,
          map_height: map_height,
          os:         client.device.os,
          ssid:       client.device.ssid,
          building:   building,
          level:      level,
        }
      end
    end
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
