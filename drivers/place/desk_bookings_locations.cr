require "json"
require "placeos-driver"
require "placeos-driver/interface/locatable"
require "./booking_model"

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

    # expose_for_analytics: {"output_key" => "booking_key->subkey"},
  })

  @expose_for_analytics : Hash(String, String) = {} of String => String
  @zone_filter : Array(String) = [] of String
  @poll_rate : Time::Span = 60.seconds
  @booking_type : String = "desk"

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

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @expose_for_analytics = setting?(Hash(String, String), :expose_for_analytics) || {} of String => String

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
    return [] of Nil if location && location != "booking"

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

      # We specify location as JSON::Any so we don't have to
      # explicitly define the type of this object
      payload = {
        "location"    => JSON::Any.new("booking"),
        "type"        => @booking_type,
        "checked_in"  => booking.checked_in,
        "asset_id"    => booking.asset_id,
        "booking_id"  => booking.id,
        "building"    => building,
        "level"       => level,
        "ends_at"     => booking.booking_end,
        "started_at"  => booking.booking_start,
        "duration"    => booking.booking_end - booking.booking_start,
        "mac"         => booking.user_id,
        "staff_email" => booking.user_email,
        "staff_name"  => booking.user_name,
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

  # Email => Array of bookings
  @bookings : Hash(String, Array(Booking)) = Hash(String, Array(Booking)).new

  # UserID =>  {Email, Name}
  @known_users : Hash(String, Tuple(String, String)) = Hash(String, Tuple(String, String)).new

  def query_desk_bookings : Nil
    bookings = [] of JSON::Any
    @zone_filter.each { |zone| bookings.concat staff_api.query_bookings(type: @booking_type, zones: {zone}).get.as_a }
    bookings = bookings.map do |booking|
      booking = Booking.from_json(booking.to_json)
      booking.user_email = booking.user_email.downcase
      booking
    end

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
