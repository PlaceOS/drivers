require "placeos-driver"
require "placeos-driver/interface/locatable"
require "../booking_model"
require "placeos"
require "json"

# reserved parking spaces
# check if any of these have been made available
# fetch the parking bookings

class Place::Parking::Locations < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "PlaceOS Parking Locations"
  generic_name :ParkingLocations
  description %(helper for handling parking bookings)

  accessor area_manager : AreaManagement_1
  accessor staff_api : StaffAPI_1

  default_settings({
    # time in seconds
    poll_rate: 60,

    # expose_for_analytics: {"output_key" => "booking_key->subkey"},
  })

  @timezone : Time::Location = Time::Location::UTC
  @expose_for_analytics : Hash(String, String) = {} of String => String
  @zone_filter : Array(String) = [] of String
  @poll_rate : Time::Span = 60.seconds

  BOOKING_TYPE      = "parking"
  RESERVED_RELEASED = "parking-released"
  METADATA_KEY      = "parking-spaces"

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      booking = Booking.from_json(payload)
      booking.user_email = booking.user_email.downcase
      booking_changed(booking)
    end
    on_update
  end

  def on_update
    @zone_filter = setting?(Array(String), :zone_filter) || [] of String
    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds
    @expose_for_analytics = setting?(Hash(String, String), :expose_for_analytics) || {} of String => String

    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)

    schedule.clear
    schedule.every(@poll_rate) { query_parking_bookings }
    schedule.in(5.seconds) { query_parking_bookings }
  end

  # level_zone_id => building_zone_id
  getter level_buildings : Hash(String, String) do
    hash = area_manager.level_buildings.get.as_h.transform_values(&.as_s)
    raise "level cache not loaded yet" unless hash.size > 0
    hash
  end

  # ===================================
  # Monitoring desk bookings
  # ===================================
  protected def booking_changed(event)
    return unless event.booking_type == BOOKING_TYPE
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
      email, _name = user_details
      {
        location:    "booking",
        assigned_to: email,
        mac_address: mac_address,
      }
    end
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    return [] of Nil if location && location != "booking"

    bookings = [] of Booking
    @bookings.each_value(&.each { |booking|
      next unless zone_id.in?(booking.zones)
      bookings << booking
    })
    map_bookings(bookings)
  end

  protected def map_bookings(bookings)
    level_to_building = level_buildings

    bookings.map do |booking|
      level = nil
      building = nil
      booking.zones.each do |zone_id|
        if build = level_to_building[zone_id]?
          building = build
          level = zone_id
          break
        end
      end

      # We specify location as JSON::Any so we don't have to
      # explicitly define the type of this object
      payload = {
        "location"   => JSON::Any.new("booking"),
        "type"       => BOOKING_TYPE,
        "checked_in" => booking.checked_in,
        "asset_id"   => booking.asset_id,
        "booking_id" => booking.id,
        "building"   => building,
        "level"      => level,
        "ends_at"    => booking.booking_end,
        "started_at" => booking.booking_start,
        "duration"   => booking.booking_end - booking.booking_start,
        "mac"        => booking.user_email,
        "staff_name" => booking.user_name,
      }

      # check for any custom data we want to include
      if !booking.extension_data.empty? && (init_data = JSON::Any.new(booking.extension_data))
        @expose_for_analytics.each do |binding, path|
          begin
            binding_keys = path.split("->")
            data = init_data
            binding_keys.each do |key|
              next if key == "extension_data"

              data = data.dig? key
              break unless data
            end
            payload[binding] = data
          rescue error
            logger.warn(exception: error) { "failed to expose #{binding}: #{path} for analytics" }
          end
        end
      end

      payload
    end
  end

  # ===================================
  # Parking and zone queries
  # ===================================

  struct ParkingSpace
    include JSON::Serializable

    property id : String
    property name : String
    property map_id : String
    property assigned_to : String?
    property assigned_name : String?

    def reserved?
      !!@assigned_to
    end
  end

  struct Details
    include JSON::Serializable

    property details : Array(ParkingSpace)
  end

  alias Zone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, Details)
  alias ChildMetadata = Array(NamedTuple(zone: Zone, metadata: Metadata))

  # Email => Array of bookings
  @bookings : Hash(String, Array(Booking)) = Hash(String, Array(Booking)).new

  # UserID =>  {Email, Name}
  @known_users : Hash(String, Tuple(String, String)) = Hash(String, Tuple(String, String)).new

  def parking_spaces : Hash(String, Array(ParkingSpace))
    metadata = ChildMetadata.from_json(staff_api.metadata_children(
      @zone_filter.first,
      METADATA_KEY
    ).get.to_json)

    zone_parking = Hash(String, Array(ParkingSpace)).new

    metadata.each do |level|
      zone = level[:zone]
      spaces = level[:metadata][METADATA_KEY].details

      zone_parking[zone.id] = spaces
    end

    zone_parking
  end

  def query_parking_bookings : Nil
    # find all the reserved parking
    reserved_spaces = parking_spaces.tap(&.each_value(&.select!(&.reserved?)))

    logger.debug do
      count = 0
      reserved_spaces.each_value { |space| count += space.size }
      "queried reserved spaces, found #{count}"
    end

    # bookings for general access spaces
    bookings = [] of JSON::Any
    @zone_filter.each { |zone| bookings.concat staff_api.query_bookings(type: BOOKING_TYPE, zones: {zone}).get.as_a }
    bookings = bookings.map do |booking|
      booking = Booking.from_json(booking.to_json)
      booking.user_email = booking.user_email.downcase
      booking
    end

    logger.debug { "queried parking bookings, found #{bookings.size}" }

    # check if any of the reserved spaces have been made available
    release_bookings = [] of JSON::Any
    @zone_filter.each { |zone| release_bookings.concat staff_api.query_bookings(type: RESERVED_RELEASED, zones: {zone}).get.as_a }
    release_bookings = release_bookings.map do |booking|
      booking = Booking.from_json(booking.to_json)
      booking.user_email = booking.user_email.downcase
      booking
    end

    logger.debug { "queried released spaces, found #{release_bookings.size}" }

    # for all reserved spaces that haven't been released, we need to
    # create a virtual booking for them
    release_bookings.each do |booking|
      parking_space = booking.asset_id
      reserved_spaces.each_value do |spaces|
        spaces.reject! { |space| space.id == parking_space }
      end
    end

    now = Time.local(@timezone)
    res_start = now.at_beginning_of_day.to_unix
    res_end = now.at_end_of_day.to_unix
    level_to_building = level_buildings

    reserved_spaces.each do |level_zone, reservations|
      building_zone = level_to_building[level_zone]?
      next unless building_zone

      reservations.each do |reservation|
        bookings << Place::Booking.new(
          id: -1,
          booking_type: BOOKING_TYPE,
          booking_start: res_start,
          booking_end: res_end,
          user_id: reservation.assigned_to.as(String),
          user_email: reservation.assigned_to.as(String),
          user_name: reservation.assigned_name.as(String),
          zones: [level_zone, building_zone],
          booked_by_name: reservation.assigned_name.as(String),
          booked_by_email: reservation.assigned_to.as(String),
          asset_id: reservation.id,
          checked_in: true,
        )
      end
    end

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
