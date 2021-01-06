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

  accessor staff_api : StaffAPI_1
  accessor findme : FindMe_1

  default_settings({
    # time in seconds
    poll_rate:     60,
    booking_type:  "desk",
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
  @poll_rate : Time::Span = 60.seconds
  @booking_type : String = "desk"
  @map_id_prefix : String = "table-"
  @s2_level : Int32 = 21

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      booking_changed(Booking.from_json(payload))
    end

    on_update
  end

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @map_id_prefix = setting?(String, :map_id_prefix).presence || "table-"

    @building_zone = setting(String, :building_zone)
    @floor_mappings = setting(Hash(String, NamedTuple(building: String, level: String)), :floor_mappings)
    @zone_filter = @floor_mappings.keys
    @s2_level = setting?(Int32, :s2_level) || 21

    # Regulary syncs the state of desk bookings
    schedule.clear
    schedule.every(@poll_rate) { @booking_lock.synchronize { query_desk_bookings } }

    # gets initial state
    schedule.in(5.seconds) { @booking_lock.synchronize { query_desk_bookings } }
  end

  # ===================================
  # Monitoring desk bookings
  # ===================================
  @booking_lock = Mutex.new

  protected def booking_changed(event)
    return unless event.booking_type == @booking_type
    matching_zones = @zone_filter & event.zones
    return if matching_zones.empty?

    @booking_lock.synchronize { query_desk_bookings }
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }

    # Desk id to booking
    bookings = email ? @booking_lookup[email.downcase] : Hash(String, Booking).new
    bookings_matched = Set(String).new

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

      build_location_response(location, level, bookings, bookings_matched, findme_building, findme_level)
    end

    locations + build_bookings(bookings, bookings_matched)
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

    bookings = @bookings[zone_id]? || Hash(String, Booking).new
    loc_type = location

    findme_details = @floor_mappings[zone_id]?
    return [] of Nil unless findme_details

    findme_building = findme_details[:building]
    findme_level = findme_details[:level]
    active_users_raw = findme.users_on(findme_building, findme_level).get.to_json
    active_users = Array(Microsoft::Location).from_json active_users_raw

    bookings_matched = Set(String).new
    locations = active_users.compact_map do |loc|
      build_location_response(loc, zone_id, bookings, bookings_matched, findme_building, findme_level, loc_type)
    end

    locations + build_bookings(bookings, bookings_matched, zone_id)
  end

  protected def build_bookings(bookings, bookings_matched, zone_id = nil)
    building_zones = [@building_zone]

    bookings.compact_map do |loc, booking|
      next if bookings_matched.includes?(loc)

      zone = zone_id || (booking.zones - building_zones).first?

      {
        location:    :desk,
        at_location: false,
        map_id:      booking.asset_id,
        level:       zone,
        building:    @building_zone,
        mac:         booking.user_id,

        booking_start: booking.booking_start,
        booking_end:   booking.booking_end,
      }
    end
  end

  protected def build_location_response(location, zone_id, bookings, bookings_matched, findme_building, findme_level, loc_type = nil)
    case location.located_using
    when "FixedLocation"
      return if loc_type.presence && loc_type != "desk"

      location_id = "#{@map_id_prefix}#{location.location_id}"

      loc = {
        location:    :desk,
        at_location: true,
        map_id:      location_id,
        level:       zone_id,
        building:    @building_zone,
        mac:         location.username,
        last_seen:   location.last_update.to_unix,

        findme_building: findme_building,
        findme_level:    findme_level,
        findme_status:   location.status,
        findme_type:     location.type,
      }

      if booking = bookings[location_id]?
        bookings_matched << location_id
        loc = loc.merge({
          booking_start: booking.booking_start,
          booking_end:   booking.booking_end,

          # This should match mac
          booked_for: booking.user_email,
        })
      end

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

  # ===================================
  # DESK AND ZONE QUERIES
  # ===================================
  class Booking
    include JSON::Serializable

    # This is to support events
    property action : String?

    property id : Int64
    property booking_type : String
    property booking_start : Int64
    property booking_end : Int64
    property timezone : String?

    # events use resource_id instead of asset_id
    property asset_id : String?
    property resource_id : String?

    def asset_id : String
      (@asset_id || @resource_id).not_nil!
    end

    property user_id : String
    property user_email : String
    property user_name : String

    property zones : Array(String)

    property checked_in : Bool?
    property rejected : Bool?

    def in_progress?
      now = Time.utc.to_unix
      now >= @booking_start && now < @booking_end
    end
  end

  # zone_id => desk_id => Booking
  @bookings : Hash(String, Hash(String, Booking)) = Hash(String, Hash(String, Booking)).new

  # Email => desk_id => Booking
  @booking_lookup : Hash(String, Hash(String, Booking)) = Hash(String, Hash(String, Booking)).new { |h, k| h[k] = {} of String => Booking }

  def query_desk_bookings : Nil
    # level_id => booking json
    booking_temp = {} of String => JSON::Any
    @zone_filter.each { |zone| booking_temp[zone] = staff_api.query_bookings(type: @booking_type, zones: {zone}).get }

    bookings_count = 0
    level_bookings = Hash(String, Hash(String, Booking)).new
    user_bookings = Hash(String, Hash(String, Booking)).new { |h, k| h[k] = {} of String => Booking }

    booking_temp.each do |zone_id, bookings_raw|
      bookings = Hash(String, Booking).new
      Array(Booking).from_json(bookings_raw.to_json).each do |booking|
        bookings_count += 1
        bookings[booking.asset_id] = booking
        user_bookings[booking.user_email.downcase][booking.asset_id] = booking
      end
      level_bookings[zone_id] = bookings
    end

    @bookings = level_bookings
    @booking_lookup = user_bookings
    logger.debug { "queried desk bookings, found #{bookings_count}" }
  end
end
