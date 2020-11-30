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
  accessor staff_api : StaffAPI_1
  accessor xy_sense : XYSense_1
  bind XYSense_1, :floors, :floor_details_changed

  default_settings({
    # time in seconds
    poll_rate:    20,
    booking_type: "desk",

    floor_mappings: {
      "xy-sense-floor-id": {
        zone_id: "placeos-zone-id",
        name:    "friendly name for documentation",
      },
    },

    # You might want to get bookings for the whole building
    zone_filter: ["placeos-zone-id"],
  })

  @floor_mappings : Hash(String, NamedTuple(zone_id: String)) = {} of String => NamedTuple(zone_id: String)
  @zone_filter : Array(String) = [] of String
  @poll_rate : Time::Span = 60.seconds
  @booking_type : String = "desk"

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

    @floor_mappings = setting(Hash(String, NamedTuple(zone_id: String)), :floor_mappings)
    @zone_filter = setting?(Array(String), :zone_filter) || @floor_mappings.map { |_, detail| detail[:zone_id] }

    # Resets @zone_mappings - used by location services
    map_zones

    # Regulary syncs the state of desk bookings
    schedule.clear
    schedule.every(@poll_rate) { query_desk_bookings }

    # gets initial state
    schedule.in(5.seconds) { query_desk_bookings }
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
        @floor_subscriptions[floor_id] = xy_sense.subscribe(floor_id) do |_sub, payload|
          level_state_change(zone_id, Array(Occupancy).from_json(payload))
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
  # Monitoring desk bookings
  # ===================================
  protected def booking_changed(event)
    return unless event.booking_type == @booking_type
    matching_zones = @zone_filter & event.zones
    return if matching_zones.empty?

    logger.debug { "booking event is in a matching zone" }

    case event.action
    when "create"
      return unless event.in_progress?
      # Check if this event is happening now
      logger.debug { "adding new booking" }
      @bookings[event.user_email] << event
    when "cancelled", "rejected"
      # delete the booking from the levels
      found = false
      @bookings[event.user_email].reject! { |booking| found = true if booking.id == event.id }
      return unless found
    when "check_in"
      return unless event.in_progress?
      @bookings[event.user_email].each { |booking| booking.checked_in = true if booking.id == event.id }
    when "changed"
      # Check if this booking is for today and update as required
      @bookings[event.user_email].reject! { |booking| booking.id == event.id }
      @bookings[event.user_email] << event if event.in_progress?
    else
      # ignore the update (approve)
      logger.debug { "booking event was ignored" }
      return
    end

    area_manager.update_available(matching_zones)
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }
    bookings = @bookings[email]? || [] of Booking
    map_bookings(bookings)
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }
    found = [] of String
    @known_users.each { |user_id, (user_email, _name)|
      found << user_id if email == user_email
    }
    found
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "searching for owner of #{mac_address}" }
    if user_details = @known_users[mac_address]?
      email, name = user_details
      {
        location:    "desk",
        assigned_to: email,
        mac_address: mac_address,
      }
    end
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    return [] of Nil unless @zone_filter.includes?(zone_id)

    bookings = [] of Booking
    @bookings.each_value(&.each { |booking|
      next unless zone_id.in?(booking.zones)
      bookings << booking
    })
    map_bookings(bookings, zone_id)
  end

  protected def space_info(zone_id, asset_id)
    if zone_id
      if space_mappings = @occupancy_mappings[zone_id]?
        space_mappings[asset_id]?
      end
    end
  end

  protected def map_bookings(bookings, include_sensor_on : String? = nil)
    sensors_matched = Set.new([] of String)
    booked = bookings.map do |booking|
      level = nil
      building = nil
      booking.zones.each do |zone_id|
        tags = @zone_mappings[zone_id]
        level = zone_id if tags.includes? "level"
        building = zone_id if tags.includes? "building"
        break if level && building
      end

      space = space_info(level, booking.asset_id)

      if space
        sensors_matched << space.space_id
        {
          location:    :desk,
          at_location: space.headcount >= 1,
          map_id:      booking.asset_id,
          level:       level,
          building:    building,
          mac:         booking.user_id,

          booking_start: booking.booking_start,
          booking_end:   booking.booking_end,

          xy_sense_space_id:  space.space_id,
          xy_sense_status:    space.status,
          xy_sense_collected: space.collected.to_unix,
          xy_sense_category:  space.details.category,
        }
      else
        {
          location:    :desk,
          at_location: booking.checked_in,
          map_id:      booking.asset_id,
          level:       level,
          building:    building,
          mac:         booking.user_id,

          booking_start: booking.booking_start,
          booking_end:   booking.booking_end,
        }
      end
    end

    # Merge in the desk usage where it's sensor only
    if include_sensor_on
      booked + @occupancy_mappings[include_sensor_on].compact_map { |space_name, space|
        next if sensors_matched.includes? space.space_id

        # Assume this means we're looking at a desk
        capacity = space.details.capacity
        if capacity == 1
          {
            location:    :desk,
            at_location: space.headcount == 1,
            map_id:      space_name,
            level:       include_sensor_on,

            xy_sense_space_id:  space.space_id,
            xy_sense_status:    space.status,
            xy_sense_collected: space.collected.to_unix,
            xy_sense_category:  space.details.category,
          }
        else
          {
            location:  :area,
            map_id:    space_name,
            level:     include_sensor_on,
            capacity:  capacity,
            headcount: space.headcount,

            xy_sense_space_id:  space.space_id,
            xy_sense_status:    space.status,
            xy_sense_collected: space.collected.to_unix,
            xy_sense_category:  space.details.category,
          }
        end
      }
    else
      booked
    end
  end

  # ===================================
  # DESK AND ZONE QUERIES
  # ===================================
  # zone id => tags
  @zone_mappings = {} of String => Array(String)

  protected def map_zones
    @zone_mappings = Hash(String, Array(String)).new do |hash, zone_id|
      # Map zones_ids to tags (level, building etc)
      hash[zone_id] = staff_api.zone(zone_id).get["tags"].as_a.map(&.as_s)
    end
  end

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

  # Email => Array of bookings
  @bookings : Hash(String, Array(Booking)) = Hash(String, Array(Booking)).new

  # UserID =>  {Email, Name}
  @known_users : Hash(String, Tuple(String, String)) = Hash(String, Tuple(String, String)).new

  def query_desk_bookings : Nil
    bookings = [] of JSON::Any
    @zone_filter.each { |zone| bookings.concat staff_api.query_bookings(type: @booking_type, zones: {zone}).get.as_a }
    bookings = bookings.map { |booking| Booking.from_json(booking.to_json) }

    logger.debug { "queried desk bookings, found #{bookings.size}" }

    new_bookings = Hash(String, Array(Booking)).new do |hash, key|
      hash[key] = [] of Booking
    end

    bookings.each do |booking|
      next if booking.rejected
      new_bookings[booking.user_email] << booking
      @known_users[booking.user_id] = {booking.user_email, booking.user_name}
    end

    @bookings = new_bookings
  end
end
