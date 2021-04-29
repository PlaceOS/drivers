module XYSense; end

require "json"
require "oauth2"
require "placeos-driver/interface/locatable"

class XYSense::LocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "XY Sense Locations"
  generic_name :XYLocationService
  description %(collects desk booking data from the staff API and overlays XY Sense data for visualising on a map)

  accessor area_manager : AreaManagement_1
  accessor xy_sense : XYSense_1
  bind XYSense_1, :floors, :floor_details_changed

  default_settings({
    floor_mappings: {
      "xy-sense-floor-id": {
        zone_id: "placeos-zone-id",
        name:    "friendly name for documentation",
      },
    },
  })

  @floor_mappings : Hash(String, NamedTuple(zone_id: String)) = {} of String => NamedTuple(zone_id: String)
  @zone_filter : Array(String) = [] of String

  def on_load
    on_update
  end

  def on_update
    @floor_mappings = setting(Hash(String, NamedTuple(zone_id: String)), :floor_mappings)
    @zone_filter = @floor_mappings.map { |_, detail| detail[:zone_id] }
  end

  # ===================================
  # Bindings into xy-sense data
  # ===================================
  class FloorDetails
    include JSON::Serializable

    property floor_id : String
    property floor_name : String
    property location_id : String
    property location_name : String

    property spaces : Array(SpaceDetails)
  end

  class SpaceDetails
    include JSON::Serializable

    property id : String
    property name : String
    property capacity : Int32
    property category : String
  end

  class Occupancy
    include JSON::Serializable

    property status : String
    property headcount : Int32
    property space_id : String

    @[JSON::Field(converter: Time::Format.new("%FT%T", Time::Location::UTC))]
    property collected : Time

    @[JSON::Field(ignore: true)]
    property! details : SpaceDetails
  end

  # Floor id => subscription
  @floor_subscriptions = {} of String => PlaceOS::Driver::Subscriptions::Subscription
  @space_details = {} of String => SpaceDetails
  @change_lock = Mutex.new

  protected def floor_details_changed(_sub = nil, payload = nil)
    @change_lock.synchronize do
      # Get the floor details from either the status push event or module update
      floors = payload ? Hash(String, FloorDetails).from_json(payload) : xy_sense.status(Hash(String, FloorDetails), :floors)
      space_details = {} of String => SpaceDetails

      # work out what we should be watching
      monitor = {} of String => String
      floors.each do |floor_id, floor|
        mapping = @floor_mappings[floor_id]?
        next unless mapping

        monitor[floor_id] = mapping[:zone_id]

        # track space data
        floor.spaces.each { |space| space_details[space.id] = space }
      end

      # unsubscribe from floors we're not interested in
      existing = @floor_subscriptions.keys
      desired = monitor.keys
      (existing - desired).each { |sub| subscriptions.unsubscribe @floor_subscriptions.delete(sub).not_nil! }

      # update to new space details
      @space_details = space_details

      # Subscribe to new data
      (desired - existing).each { |floor_id|
        zone_id = monitor[floor_id]
        @floor_subscriptions[floor_id] = xy_sense.subscribe(floor_id) do |_sub, message|
          level_state_change(zone_id, Array(Occupancy).from_json(message))
        end
      }
    end
  end

  # Zone_id => area => occupancy details
  @occupancy_mappings : Hash(String, Hash(String, Occupancy)) = {} of String => Hash(String, Occupancy)

  def level_state_change(zone_id : String, spaces : Array(Occupancy))
    area_occupancy = {} of String => Occupancy
    spaces.each do |space|
      space.details = @space_details[space.space_id]
      area_occupancy[space.details.name] = space
    end
    @occupancy_mappings[zone_id] = area_occupancy
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

    @occupancy_mappings[zone_id].compact_map do |space_name, space|
      # Assume this means we're looking at a desk
      capacity = space.details.capacity
      if capacity == 1
        next unless space.headcount > 0
        next if location.presence && location != "desk"
        {
          location:    :desk,
          at_location: space.headcount,
          map_id:      space_name,
          level:       zone_id,
          capacity:    capacity,

          xy_sense_space_id:  space.space_id,
          xy_sense_status:    space.status,
          xy_sense_collected: space.collected.to_unix,
          xy_sense_category:  space.details.category,
        }
      else
        next if location.presence && location != "area"
        {
          location:    :area,
          at_location: space.headcount,
          map_id:      space_name,
          level:       zone_id,
          capacity:    capacity,

          xy_sense_space_id:  space.space_id,
          xy_sense_status:    space.status,
          xy_sense_collected: space.collected.to_unix,
          xy_sense_category:  space.details.category,
        }
      end
    end
  end
end
