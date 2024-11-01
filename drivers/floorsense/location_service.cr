require "placeos-driver"
require "placeos-driver/interface/lockers"
require "placeos-driver/interface/locatable"
require "uri"
require "json"
require "oauth2"
require "./models"

class Floorsense::LocationService < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "Floorsense Location Service"
  generic_name :FloorsenseLocationService
  description %(collects desk booking data from the staff API and overlays Floorsense data for visualising on a map)

  accessor floorsense : Floorsense_1
  accessor staff_api : StaffAPI_1

  default_settings({
    floor_mappings: {
      "planid": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
    include_bookings: false,

    user_lookup:       "email",
    floorsense_filter: "email",
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  # Level zone => plan_id
  @zone_mappings : Hash(String, String) = {} of String => String
  # Level zone => building_zone
  @building_mappings : Hash(String, String?) = {} of String => String?

  @include_bookings : Bool = false

  # eui64 => floorsense desk id
  @eui64_to_desk_id : Hash(String, String) = {} of String => String

  def on_load
    on_update
  end

  def on_update
    @include_bookings = setting?(Bool, :include_bookings) || false
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @user_lookup = setting?(String, :user_lookup).presence || "email"
    @floorsense_filter = setting?(String, :floorsense_filter).presence || "email"
    @create_floorsense_users = setting?(Bool, :create_floorsense_users) || false
    @floor_mappings.each do |plan_id, details|
      level = details[:level_id]
      @building_mappings[level] = details[:building_id]
      @zone_mappings[level] = plan_id
    end
  end

  def eui64_to_desk_id(id : String)
    @eui64_to_desk_id[id]?
  end

  # ===================================
  # Get and set a users desk height
  # ===================================

  @user_lookup : String = "email"
  @floorsense_filter : String = "email"
  @create_floorsense_users : Bool = true

  def get_floorsense_user(place_user_id : String) : String
    place_user = staff_api.user(place_user_id).get
    placeos_staff_id = place_user[@user_lookup].as_s

    user_query = case @floorsense_filter
                 when "name"
                   floorsense.user_list(name: placeos_staff_id)
                 when "email"
                   floorsense.user_list(email: placeos_staff_id)
                 else
                   floorsense.user_list(description: placeos_staff_id)
                 end
    floorsense_users = user_query.get.as_a

    user_id = floorsense_users.first?.try(&.[]("uid").as_s)
    user_id ||= floorsense.create_user(place_user["name"].as_s, place_user["email"].as_s, placeos_staff_id).get["uid"].as_s if @create_floorsense_users
    raise "Floorsense user not found for #{placeos_staff_id}" unless user_id

    card_number = place_user["card_number"]?.try(&.as_s)
    spawn { ensure_card_synced(card_number, user_id) } if user_id && card_number && !card_number.empty?
    user_id
  end

  protected def ensure_card_synced(card_number : String, user_id : String) : Nil
    existing_user = begin
      floorsense.get_rfid(card_number).get["uid"].as_s
    rescue
      nil
    end

    if existing_user != user_id
      floorsense.delete_rfid(card_number)
      floorsense.create_rfid(user_id, card_number)
    end
  rescue error
    logger.warn(exception: error) { "failed to sync card number #{card_number} for user #{user_id}" }
  end

  def get_place_user_id : String
    user_id = invoked_by_user_id
    raise "must be invoked by a user" unless user_id
    user_id
  end

  def get_desk_height_sit
    user_id = get_place_user_id
    uid = get_floorsense_user(user_id)
    floorsense.get_setting("desk_height_sit", uid).get["value"]
  end

  def get_desk_height_stand
    user_id = get_place_user_id
    uid = get_floorsense_user(user_id)
    floorsense.get_setting("desk_height_stand", uid).get["value"]
  end

  def set_desk_height_sit(value : UInt32)
    user_id = get_place_user_id
    uid = get_floorsense_user(user_id)
    floorsense.set_setting("desk_height_sit", value, uid)
  end

  def set_desk_height_stand(value : UInt32)
    user_id = get_place_user_id
    uid = get_floorsense_user(user_id)
    floorsense.set_setting("desk_height_stand", value, uid)
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
    floor_mac = URI::Params.parse mac_address
    user = floorsense.at_location(floor_mac["cid"], floor_mac["key"]).get
    {
      location:    "desk",
      assigned_to: user["name"].as_s,
      mac_address: mac_address,
    }
  rescue
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Nil if location && location != "desk"

    plan_id = @zone_mappings[zone_id]?
    return [] of Nil unless plan_id

    building = @building_mappings[zone_id]?

    raw_desks = floorsense.desks(plan_id).get.to_json
    desks = Array(DeskStatus).from_json(raw_desks).compact_map do |desk|
      @eui64_to_desk_id[desk.eui64] = desk.key

      if desk.occupied
        {
          location:    :desk,
          at_location: 1,
          map_id:      desk.key,
          level:       zone_id,
          building:    building,
          capacity:    1,

          # So we can look up who is at a desk at some point in the future
          mac: "cid=#{desk.cid}&key=#{desk.key}",

          floorsense_status:    desk.status,
          floorsense_desk_type: desk.desk_type,
        }
      end
    end

    current = [] of BookingStatus

    if @include_bookings
      raw_bookings = floorsense.bookings(plan_id).get.to_json
      Hash(String, Array(BookingStatus)).from_json(raw_bookings).each_value do |bookings|
        current << bookings.first unless bookings.empty?
      end
    end

    current.map { |booking|
      {
        location:    :booking,
        type:        "desk",
        checked_in:  booking.active,
        asset_id:    booking.key,
        booking_id:  booking.booking_id,
        building:    building,
        level:       zone_id,
        ends_at:     booking.finish,
        mac:         "cid=#{booking.cid}&key=#{booking.key}",
        staff_email: booking.user.try &.email.try(&.downcase),
        staff_name:  booking.user.try &.name,
      }
    } + desks
  end
end
