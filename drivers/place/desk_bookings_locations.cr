module Place; end

require "json"
require "placeos-driver/interface/locatable"

class Place::DeskBookingsLocations < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "PlaceOS Desk Bookings Locations"
  generic_name :DeskBookings
  description %(collects desk booking data from the staff API for visualising on a map)

  accessor area_manager : AreaManagement_1
  accessor staff_api : StaffAPI_1

  default_settings({
    zone_filter: ["placeos-zone-id"],

    # time in seconds
    poll_rate:    60,
    booking_type: "desk",
  })

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
    @zone_filter = setting?(Array(String), :zone_filter) || [] of String
    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds

    @booking_type = setting?(String, :booking_type).presence || "desk"

    map_zones
    schedule.clear
    schedule.every(@poll_rate) { query_desk_bookings }
    schedule.in(5.seconds) { query_desk_bookings }
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
    bookings = [] of Booking
    @bookings.each_value(&.each { |booking|
      next unless zone_id.in?(booking.zones)
      bookings << booking
    })
    map_bookings(bookings)
  end

  protected def map_bookings(bookings)
    bookings.map do |booking|
      level = nil
      building = nil
      booking.zones.each do |zone_id|
        tags = @zone_mappings[zone_id]
        level = zone_id if tags.includes? "level"
        building = zone_id if tags.includes? "building"
        break if level && building
      end

      {
        location:    :booking,
        checked_in:  booking.checked_in,
        asset_id:    booking.asset_id,
        booking_id:  booking.id,
        building:    building,
        level:       level,
        ends_at:     booking.booking_end,
        mac:         booking.user_id,
        staff_email: booking.user_email,
        staff_name:  booking.user_name,
      }
    end
  end

  # ===================================
  # DESK AND ZONE QUERIES
  # ===================================
  # zone id => tags
  @zone_mappings = {} of String => Array(String)

  class ZoneDetails
    include JSON::Serializable
    property tags : Array(String)
  end

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
