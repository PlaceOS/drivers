require "uri"
require "json"
require "oauth2"
require "placeos-driver"
require "placeos-driver/interface/lockers"
require "./models"

class Floorsense::LockerLocationService < PlaceOS::Driver
  include Interface::Lockers
  alias PlaceLocker = PlaceOS::Driver::Interface::Lockers::PlaceLocker

  descriptive_name "Floorsense Locker Location Service"
  generic_name :FloorsenseLockers
  description %(collects locker booking data from the staff API and overlays Floorsense data for visualising on a map)

  accessor floorsense : Floorsense_1
  accessor staff_api : StaffAPI_1

  bind Floorsense_1, :controllers, :controllers_changed

  default_settings({
    # execute Floorsense.controller_list to define these mappings
    locker_building_location: "Building Location",
    locker_floor_mappings:    {
      "Floor Location": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },

    user_lookup:             "email",
    floorsense_filter:       "email",
    create_floorsense_users: true,
  })

  @building_location : String = ""
  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)

  def on_update
    @building_location = setting(String, :locker_building_location)
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :locker_floor_mappings)

    @user_lookup = setting?(String, :user_lookup).presence || "email"
    @floorsense_filter = setting?(String, :floorsense_filter).presence || "email"
    @create_floorsense_users = setting?(Bool, :create_floorsense_users) || false
  end

  # Controller id => Controller info
  getter controllers : Hash(Int32, ControllerInfo) = {} of Int32 => ControllerInfo

  # controller id => Locker bank ids
  @locker_banks : Hash(Int32, Array(Int64)) = {} of Int32 => Array(Int64)

  # level zone_id => controller ids
  getter zone_mappings : Hash(String, Array(Int32)) = {} of String => Array(Int32)
  getter zone_building : String? = nil

  private def controllers_changed(_subscription, new_value)
    logger.debug { "controller list changed: #{new_value}" }

    # find the relevant controllers
    @controllers = Hash(Int32, ControllerInfo).from_json(new_value).reject! do |_key, value|
      !value.lockers && value.locations.includes?(@building_location)
    end

    # map the locker banks to these controllers
    @locker_banks = locker_banks.transform_values do |locker_banks, controller_id|
      locker_banks.map do |bank|
        bank["bid"].as_i64
      end
    end

    # map the controllers on each floor
    @floor_mappings.each do |floor_name, zones|
      if building_zone = zones[:building_id].presence
        @zone_building = building_zone
      end

      @zone_mappings[zones[:level_id]] = @controllers.values.compact_map do |info|
        info.controller_id if info.locations.includes?(floor_name)
      end
    end
  rescue ex
    logger.warn(exception: ex) { "failed to parse controller list" }
  end

  def locker_banks
    banks = {} of Int32 => Array(JSON::Any)
    @controllers.each_key do |controller_id|
      if json = (floorsense.bank_list(controller_id).get rescue nil)
        banks[controller_id] = json.as_a
      end
    end
    banks
  end

  # ===================================
  # User management
  # ===================================

  @user_lookup : String = "email"
  @floorsense_filter : String = "email"
  @create_floorsense_users : Bool = true

  def get_floorsense_user(place_user_id : String) : String
    place_user = staff_api.user(place_user_id).get
    placeos_staff_id = place_user[@user_lookup].as_s

    logger.debug { "found place id: #{placeos_staff_id}" }

    user_query = case @floorsense_filter
                 when "name"
                   floorsense.user_list(name: placeos_staff_id)
                 when "email"
                   floorsense.user_list(email: placeos_staff_id)
                 else
                   floorsense.user_list(description: placeos_staff_id)
                 end
    floorsense_users = user_query.get.as_a

    logger.debug { "found #{floorsense_users.size} matching floorsense users" }

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

  def get_place_user_id(floorsense_id : String | Int64) : String
    floor_user = floorsense.get_user(floorsense_id).get
    place_lookup = case @floorsense_filter
                   when "name", "email"
                     floor_user[@floorsense_filter].as_s
                   else
                     floor_user["desc"].as_s
                   end

    return place_lookup if place_lookup.starts_with?("user-") && !place_lookup.includes?('@')
    staff_api.user(place_lookup).get["id"].as_s
  end

  def get_user_email(floorsense_id : String | Int64) : String
    floor_user = floorsense.get_user(floorsense_id).get
    begin
      floor_user["email"].as_s
    rescue
      place_lookup = case @floorsense_filter
                     when "name", "email"
                       floor_user[@floorsense_filter].as_s
                     else
                       floor_user["desc"].as_s
                     end
      staff_api.user(place_lookup).get["email"].as_s
    end
  end

  # ========================================
  # Lockers Interface
  # ========================================

  class ::PlaceOS::Driver::Interface::Lockers::PlaceLocker
    def initialize(@bank_id, locker : ::Floorsense::LockerBooking, @building = nil, @level = nil)
      @locker_id = locker.key
      @locker_name = locker.key
      @mac = "lc=#{locker.controller_id}&lk=#{locker.key}"
      @expires_at = Time.unix(locker.finish)
      @allocated = !locker.released?
    end
  end

  # allocates a locker now, the allocation may expire
  @[Security(Level::Administrator)]
  def locker_allocate(
    # PlaceOS user id
    user_id : String,

    # the locker location
    bank_id : String | Int64,

    # allocates a random locker if this is nil
    locker_id : String | Int64? = nil,

    # attempts to create a booking that expires at the time specified
    expires_at : Int64? = nil
  ) : PlaceLocker
    floorsense_user_id = get_floorsense_user(user_id)
    duration = (expires_at - Time.local.to_unix) // 60 if expires_at
    booking = LockerBooking.from_json floorsense.locker_reservation(
      locker_key: locker_id,
      user_id: floorsense_user_id,
      duration: duration,
      controller_id: bank_id
    ).get.to_json

    level = nil
    @zone_mappings.each do |level_zone, controllers|
      if bank_id.in?(controllers)
        level = level_zone
        break
      end
    end

    PlaceLocker.new(bank_id, booking, @zone_building, level)
  end

  # return the locker to the pool
  @[Security(Level::Administrator)]
  def locker_release(
    bank_id : String | Int64,
    locker_id : String | Int64,

    # release / unshare just this user - otherwise release the whole locker
    owner_id : String? = nil
  ) : Nil
    if place_id = owner_id.presence
      floorsense_user_id = get_floorsense_user(place_id)
    end

    reservation = Array(LockerBooking).from_json(floorsense.locker_reservations(
      active: true,
      user_id: floorsense_user_id,
      controller_id: bank_id
    ).get.to_json).find! { |booking| booking.key == locker_id }

    floorsense.locker_release(reservation.reservation_id).get
  end

  # a list of lockers that are allocated to the user
  @[Security(Level::Administrator)]
  def lockers_allocated_to(user_id : String) : Array(PlaceLocker)
    floorsense_user_id = get_floorsense_user(user_id)
    Array(LockerBooking).from_json(floorsense.locker_reservations(
      active: true,
      user_id: floorsense_user_id
    ).get.to_json).compact_map do |floor_booking|
      level = nil
      @zone_mappings.each do |level_zone, controllers|
        if floor_booking.controller_id.in?(controllers)
          level = level_zone
          break
        end
      end

      # if we can find the level then we are interested in this booking
      if level
        PlaceLocker.new(get_locker_bank(floor_booking.key), floor_booking, @zone_building, level)
      end
    end
  end

  @[Security(Level::Administrator)]
  def locker_share(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String,
    share_with : String
  ) : Nil
    floorsense_user_id = get_floorsense_user(owner_id)
    share_with = get_floorsense_user(share_with)

    reservation = Array(LockerBooking).from_json(floorsense.locker_reservations(
      active: true,
      user_id: floorsense_user_id,
      controller_id: bank_id
    ).get.to_json).find! { |booking| booking.key == locker_id }

    floorsense.locker_share(reservation.reservation_id, share_with).get
  end

  @[Security(Level::Administrator)]
  def locker_unshare(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String,
    # the individual you previously shared with (optional)
    shared_with_id : String? = nil
  ) : Nil
    floorsense_user_id = get_floorsense_user(owner_id)

    if reservation = Array(LockerBooking).from_json(floorsense.locker_reservations(
         active: true,
         user_id: floorsense_user_id,
         controller_id: bank_id,
         shared: true,
       ).get.to_json).find { |booking| booking.key == locker_id }
      res_id = reservation.reservation_id
      if shared_with = shared_with_id.presence
        shared_with_id = get_floorsense_user(shared_with)
        floorsense.locker_unshare(res_id, shared_with_id).get
      else
        floorsense.locker_shared?(res_id).get.as_a.map do |shared_with|
          floorsense.locker_unshare(res_id, shared_with["uid"].as_s).get
        end
      end
    end
  end

  # a list of user-ids that the locker is shared with.
  # this can be placeos user ids or emails
  @[Security(Level::Administrator)]
  def locker_shared_with(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String
  ) : Array(String)
    floorsense_user_id = get_floorsense_user(owner_id)

    if reservation = Array(LockerBooking).from_json(floorsense.locker_reservations(
         active: true,
         user_id: floorsense_user_id,
         controller_id: bank_id,
         shared: true,
       ).get.to_json).find { |booking| booking.key == locker_id }
      return floorsense.locker_shared?(reservation.reservation_id).get.as_a.map do |shared_with|
        get_place_user_id shared_with["uid"].as_s
      end
    end

    [] of String
  end

  @[Security(Level::Administrator)]
  def locker_unlock(
    bank_id : String | Int64,
    locker_id : String | Int64,

    # sometimes required by locker systems
    owner_id : String? = nil,
    # time in seconds the locker should be unlocked
    # (can be ignored if not implemented)
    open_time : Int32 = 60,
    # optional pin code - if user entered from a kiosk
    pin_code : String? = nil
  ) : Nil
    floorsense_user_id = get_floorsense_user(owner_id.to_s) if owner_id.presence
    floorsense.locker_unlock(
      locker_key: locker_id.to_s,
      user_id: floorsense_user_id,
      pin: pin_code
    )
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
    # we could find the floorsense user, grab the reservations the user has
    # and list them here, but probably not amazingly useful
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    return nil unless mac_address.starts_with?("lc=")
    floor_mac = URI::Params.parse mac_address
    controller_id = floor_mac["lc"]
    locker_key = floor_mac["lk"]
    reservations = Array(LockerBooking).from_json(floorsense.locker_reservations(active: true, controller_id: controller_id).get.to_json)

    if reservation = reservations.find { |booking| booking.key == locker_key }
      {
        location:    "locker",
        assigned_to: get_user_email(reservation.user_id),
        mac_address: mac_address,
      }
    end
  rescue
    nil
  end

  # locker bank ids
  @locker_key_to_bank = {} of String => String | Int64

  def get_locker_bank(locker_key : String)
    if bank_id = @locker_key_to_bank[locker_key]?
      return bank_id
    end

    bank_id = floorsense.locker_info(locker_key).get["controller_id"].as_i64
    @locker_key_to_bank[locker_key] = bank_id
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching lockers in zone #{zone_id}" }
    return [] of Nil if location && location != "locker"

    controller_list = @zone_mappings[zone_id]?
    return [] of Nil unless controller_list

    building = @zone_building
    controller_list.flat_map do |controller_id|
      bookings = Array(LockerBooking).from_json(floorsense.locker_reservations(active: true, controller_id: controller_id).get.to_json)
      bookings.map do |booking|
        PlaceLocker.new(get_locker_bank(booking.key), booking, @zone_building, zone_id)
      end
    end
  end
end
