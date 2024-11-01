require "s2_cells"
require "./mist_models"
require "placeos-driver"
require "placeos-driver/interface/locatable"

class Juniper::MistLocationService < PlaceOS::Driver
  include Interface::Locatable

  generic_name :MistLocations
  descriptive_name "Juniper Mist Locations"
  description "Juniper Mist location service"

  default_settings({
    floorplan_mappings: {
      "mist_map_id" => {
        "building":   "zone-12345",
        "level":      "zone-123456",
        "level_name": "BUILDING - L1",
      },
    },

    # Time before a user location is considered probably too old
    max_location_age: 6,
  })

  # accessor dashboard : Dashboard_1
  accessor mist : MistWebsocket_1

  # map_ids => data
  @floorplan_mappings : Hash(String, Hash(String, String | Int32)) = Hash(String, Hash(String, String | Int32)).new
  @floorplan_sizes = {} of String => MapImage

  @max_location_age : Time::Span = 6.minutes

  def on_load
    on_update
  end

  def on_update
    @floorplan_mappings = setting?(Hash(String, Hash(String, String | Int32)), :floorplan_mappings) || @floorplan_mappings
    @max_location_age = (setting?(UInt32, :max_location_age) || 6).minutes

    schedule.clear
    schedule.every(10.minutes) { sync_map_sizes }
    schedule.in(20.seconds) { sync_map_sizes }
  end

  protected def sync_map_sizes
    maps = {} of String => MapImage
    Array(Map).from_json(mist.maps.get.to_json).each do |map|
      unless map.is_a?(MapImage)
        # TODO:: it might be possible to work out the size based on geo coordinates.
        logger.warn { "mist map #{map.id} is not an image, cannot determine size" }
        next
      end
      maps[map.id] = map
    end
    @floorplan_sizes = maps
  end

  # ============================
  # Location Services Interface:
  # ============================

  # array of devices and their x, y coordinates, that are associated with this user
  def locate_user(email : String? = nil, username : String? = nil)
    clients = Array(Client).from_json mist.locate(username.presence || email.presence.not_nil!).get.to_json

    ignore_older = @max_location_age.ago.to_unix
    clients.compact_map { |client|
      next if client.last_seen < ignore_older
      map_id = client.map_id
      mappings = @floorplan_mappings[map_id]?
      next unless mappings

      building = mappings["building"]?.as(String?)
      level = mappings["level"]?.as(String?)
      map_width, map_height = get_floorplan_size(map_id, mappings)

      {
        location:         :wireless,
        coordinates_from: "top-left",
        x:                client.x,
        y:                client.y,
        # not sure if we can get geo coordinates...
        # lon:              lon,
        # lat:              lat,
        # s2_cell_id:       lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
        mac:          client.mac,
        variance:     client.accuracy,
        last_seen:    client.last_seen,
        map_width:    map_width,
        map_height:   map_height,
        manufacturer: client.manufacture,
        os:           client.os,
        ssid:         client.ssid,
        building:     building,
        level:        level,
        mist_map_id:  map_id,
      }
    }
  end

  # return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    mist.macs_assigned_to(username.presence || email.presence.not_nil!).get.as_a.map &.as_s
  end

  # Proxies the data to the mist driver
  @[Security(PlaceOS::Driver::Level::Administrator)]
  def mac_address_mappings(username : String, macs : Array(String), domain : String = "")
    mist.mac_address_mappings(username, macs, domain)
  end

  # return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String) : OwnershipMAC?
    lookup = format_mac(mac_address)
    if user = mist.ownership_of(lookup).get.as_s?
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
    maps = [] of String
    @floorplan_mappings.each do |map_id, data|
      maps << map_id if data.values.includes?(zone_id)
    end
    logger.debug { "found matching mist maps: #{maps}" }
    return [] of String if maps.empty?

    ignore_older = @max_location_age.ago.to_unix

    # Find the devices that are on the matching floors
    all_devices = maps.flat_map do |map_id|
      clients = mist.status?(Array(Client), map_id) || [] of Client

      mappings = @floorplan_mappings[map_id]
      building = mappings["building"]?.as(String?)
      level = mappings["level"]?.as(String?)
      map_width, map_height = get_floorplan_size(map_id, mappings)

      clients.compact_map do |client|
        next if client.last_seen < ignore_older

        {
          location:         :wireless,
          coordinates_from: "top-left",
          x:                client.x,
          y:                client.y,
          # not sure if we can get geo coordinates...
          # lon:              lon,
          # lat:              lat,
          # s2_cell_id:       lat ? S2Cells::LatLon.new(lat.not_nil!, lon.not_nil!).to_token(@s2_level) : nil,
          mac:          client.mac,
          variance:     client.accuracy,
          last_seen:    client.last_seen,
          map_width:    map_width,
          map_height:   map_height,
          manufacturer: client.manufacture,
          os:           client.os,
          ssid:         client.ssid,
          building:     building,
          level:        level,
          mist_map_id:  map_id,
        }
      end
    end
  end

  protected def get_floorplan_size(map_id, mappings)
    map_details = @floorplan_sizes[map_id]?

    map_width = -1
    map_height = -1
    if map_details
      map_width = map_details.width
      map_height = map_details.height
    else
      map_width = (mappings["width"]? || map_width).as(Int32)
      map_height = (mappings["height"]? || map_width).as(Int32)
    end

    {map_width, map_height}
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
