require "placeos-driver"
require "placeos-driver/interface/locatable"
require "./models"

class GoBright::LocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "GoBright Location Service"
  generic_name :GoBrightLocationService
  description %(collects GoBright data for visualising on a map)

  accessor staff_api : StaffAPI_1
  accessor gobright : GoBright_1
  accessor area_management : AreaManagement_1

  default_settings({
    gobright_floor_mappings: {
      "placeos_zone_id": {
        location_id: "level",
        name:        "friendly name for documentation",
      },
    },
    return_empty_spaces: true,
    desk_space_types:    ["desk"],
    space_cache_cron:    "0 5 * * *",
  })

  # place_zone_id => gobright_location_id
  @floor_mappings : Hash(String, String) = {} of String => String
  @zone_filter : Array(String) = [] of String
  @desk_space_types : Array(SpaceType) = [SpaceType::Desk]
  @default_space_type : SpaceType?

  struct Mapping
    include JSON::Serializable
    getter location_id : String
  end

  struct LevelCapacity
    include JSON::Serializable

    getter desk_mappings : Hash(String, String)
  end

  def on_update
    @return_empty_spaces = setting?(Bool, :return_empty_spaces) || false
    @desk_space_types = setting?(Array(SpaceType), :desk_space_types) || [SpaceType::Desk] # By default the setting will not be present (so will be nil, which should query all Space Types)
    @default_space_type = setting?(SpaceType, :default_space_type) || nil
    @floor_mappings = setting(Hash(String, Mapping), :gobright_floor_mappings).transform_values(&.location_id)
    @zone_filter = @floor_mappings.keys
    @building_id = nil

    timezone = Time::Location.load(system.timezone.presence || "Australia/Sydney")
    schedule.clear
    schedule.cron(setting?(String, :space_cache_cron) || "0 5 * * *", timezone) { cache_space_details }
    schedule.every(10.minutes) { @level_details = nil }
  end

  getter level_details : Hash(String, LevelCapacity) do
    Hash(String, LevelCapacity).from_json area_management.level_details.get.to_json
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    raise error
  end

  getter building_id : String { get_building_id }
  getter space_details : Hash(String, Space) { cache_space_details }

  def cache_space_details
    space_details = {} of String => Space
    Array(Space).from_json(gobright.spaces.get.to_json).each do |space|
      space_details[space.id] = space
    end
    @space_details = space_details
  end

  # ===================================
  # Locatable Interface functions
  # ===================================

  # zone_id => bookings
  @cached_booking_data = {} of String => Hash(String, Occurrence)

  # NOTE:: we could keep track of current bookings and then use that information to assign ownership of a desk
  # if the desks are being booked via the check-in/check-out
  # this would allow us to locate
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for user #{email}" }
    matches = [] of Occurrence

    # find bookings with the user
    @cached_booking_data.each do |zone_id, lookup|
      lookup.each_value do |booking|
        next unless booking.organizer.try(&.email_address) == email
        matches << booking
      end
    end

    # return the data in the correct format
    matches.compact_map do |booking|
      zone_id = booking.zone_id
      map_booking(booking, booking.matched_space, zone_id, level_details[zone_id]?.try(&.desk_mappings))
    end
  end

  NO_MATCHES = [] of String

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    return NO_MATCHES unless email
    logger.debug { "checking if any bookings for email: #{email}" }
    matches = [] of String
    @cached_booking_data.each do |zone_id, lookup|
      lookup.each_value do |booking|
        matches << "gobright-#{booking.id}" if booking.organizer.try(&.email_address) == email
      end
    end
    matches
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "checking ownership of: #{mac_address}" }
    return unless mac_address.starts_with?("gobright-")

    id = mac_address.split("gobright-")[1]
    @cached_booking_data.each do |zone_id, lookup|
      if booking = lookup[id]?
        return {
          location:    "booking",
          assigned_to: booking.organizer.try(&.email_address) || booking.attendees.first.email_address.as(String),
          mac_address: mac_address,
        }
      end
    end
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }

    if building_id == zone_id
      return @zone_filter.flat_map { |level_id| device_locations(level_id, location) }
    end
    return [] of Nil unless @zone_filter.includes?(zone_id)
    return [] of Nil if location && !location.in?({"desk", "area", "booking"})

    # grab all the spaces for the current zone_id
    gobright_location_id = @floor_mappings[zone_id]
    spaces = {} of String => Space
    space_details.each_value do |space|
      next unless space.location_id == gobright_location_id
      spaces[space.id] = space.dup
    end

    # retrieve desk details and perform gobright_desk_name to departments (groups) mapping
    desks_meta = staff_api.metadata(zone_id, "desks").get.as_h["desks"].as_h
    desk_groups_mapping = desks_meta["details"].as_a.map do |desk|
      desk_h = desk.as_h
      gobright_desk_name = desk_h["gobright_desk_name"].as_s
      departments = begin
        if (arr = desk_h["departments"].as_a?)
          arr.empty? ? ["none"] : arr.map(&.as_s)
        elsif desk_h.has_key?("departments") && desk_h["departments"].raw.is_a?(String)
          [desk_h["departments"].as_s]
        else
          ["none"]
        end
      end
      {gobright_desk_name, departments}
    end.to_h

    # mark if the space is occupied
    occupancy = Array(Occupancy).from_json(gobright.live_occupancy(gobright_location_id, @default_space_type).get.to_json)
    occupancy.each do |details|
      space = spaces[details.id]?
      next unless space

      space.occupied = details.occupied? || false
    end

    # build the response
    desk_types = @desk_space_types
    occupancy_locs = spaces.values.compact_map do |space|
      loc_type = space.type.in?(desk_types) ? "desk" : "area"
      next if location.presence && location != loc_type

      if (occupied = space.occupied?) || @return_empty_spaces
        {
          location:             loc_type,
          at_location:          occupied ? 1 : 0,
          map_id:               space.name,
          level:                zone_id,
          building:             building_id,
          capacity:             space.capacity || 1,
          group:                desk_groups_mapping.fetch(space.name, ["none"]).first,
          gobright_location_id: gobright_location_id,
          gobright_space_name:  space.name,
          gobright_space_type:  space.type,
          gobright_space_id:    space.id,
        }
      end
    end

    return spaces if location && location != "booking"

    # mark if the desk is booked
    bookings = Array(Occurrence).from_json(gobright.bookings(1.minutes.ago.to_unix, 10.minutes.from_now.to_unix, gobright_location_id).get.to_json)

    lookup = {} of String => Occurrence
    booking_locs = bookings.compact_map do |occurrence|
      space = nil
      occurrence.spaces.each do |details|
        space = spaces[details.id]?
        break if space
      end

      next unless space
      occurrence.zone_id = zone_id
      occurrence.matched_space = space
      lookup[occurrence.id] = occurrence
      map_booking(occurrence, space, zone_id)
    end

    @cached_booking_data[zone_id] = lookup

    # merge occupancy and spaces
    booking_locs.map(&.as(typeof(booking_locs[0]) | typeof(occupancy_locs[0]))) + occupancy_locs.map(&.as(typeof(booking_locs[0]) | typeof(occupancy_locs[0])))
  end

  protected def map_booking(occurrence, space, zone_id, mappings = nil)
    owner = occurrence.organizer || occurrence.attendees.first?
    starting = occurrence.start_date.to_unix
    ending = occurrence.end_date.to_unix
    space_name = space.name
    map_id = mappings ? (mappings[space_name]? || space_name) : space_name

    {
      location:   :booking,
      type:       "desk",
      checked_in: !!occurrence.confirmation_active,

      # We supply map_id here as this will be mapped to the correct id
      # and the frontend preferences map_id over asset_id
      asset_id: space_name,
      map_id:   map_id,

      booking_id:  occurrence.id,
      building:    building_id,
      level:       zone_id,
      ends_at:     ending,
      started_at:  starting,
      duration:    ending - starting,
      mac:         "gobright-#{occurrence.id}",
      staff_email: owner.try &.email_address,
      staff_name:  owner.try &.name,
    }
  end
end
