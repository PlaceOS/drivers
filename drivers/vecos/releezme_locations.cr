require "placeos-driver"
require "placeos-driver/interface/lockers"
require "placeos-driver/interface/locatable"
require "./releezme/*"

class Vecos::ReleezmeLocations < PlaceOS::Driver
  include Interface::Locatable
  include Interface::Lockers

  alias PlaceLocker = PlaceOS::Driver::Interface::Lockers::PlaceLocker

  descriptive_name "Vecos Locker Locations"
  generic_name :LockerLocations

  accessor staff_api : StaffAPI_1
  accessor releezme : ReleezmeLockers_1

  default_settings({
    # the users id
    user_id_key:          "email",
    vecos_floor_mappings: {
      "placeos_zone_id": {
        section_id: "level",
        name:       "friendly name for documentation",
      },
    },
    door_number_lookup: false,
  })

  def on_update
    @door_number_lookup = setting?(Bool, :door_number_lookup) || false
    @user_id_key = setting?(String, :user_id_key) || "email"
    @floor_mappings = setting(Hash(String, Mapping), :vecos_floor_mappings).transform_values(&.section_id)
    @zone_filter = @floor_mappings.keys
    @building_id = nil

    if @door_number_lookup
      schedule.clear
      schedule.in(rand(10).seconds) do
        @floor_mappings.each_key do |zone_id|
          device_locations(zone_id)
        end
      end
    end
  end

  # place_zone_id => releexme_section_id
  @floor_mappings : Hash(String, String) = {} of String => String
  @zone_filter : Array(String) = [] of String
  @user_id_key : String = "email"
  @door_number_lookup : Bool = false
  @last_mapped : Time = 4.hours.ago

  struct Mapping
    include JSON::Serializable
    getter section_id : String
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

  def lookup_id(locker_id : String) : String
    if @door_number_lookup
      status?(String, locker_id.downcase) || locker_id
    else
      locker_id
    end
  end

  # ========================================
  # Lockers Interface
  # ========================================

  class PlaceLocker
    def initialize(
      locker : Vecos::Locker,
      allocated : Bool = false,
      @building = nil,
      @level = nil
    )
      @locker_uid = locker.id
      @locker_id = locker.full_door_number
      @bank_id = locker.locker_bank_id
      @group_id = locker.locker_group_id
      @locker_name = locker.full_door_number
      @expires_at = locker.expires_date_time_utc
      @allocated = if allocations = locker.number_of_allocations
                     (allocations > 0) || allocated
                   else
                     allocated
                   end
    end

    def initialize(booking : Vecos::Booking)
      @locker_uid = booking.locker_id
      @locker_id = booking.full_door_number
      @bank_id = booking.locker_bank_id
      @group_id = booking.locker_group_id
      @locker_name = booking.full_door_number
      @expires_at = booking.ending
      @allocated = true
      @allocation_id = booking.id
    end

    getter group_id : String? = nil
    getter locker_uid : String? = nil
  end

  protected def get_group_id(user_id, bank_id)
    section_id = releezme.bank(bank_id).get["SectionId"].as_s
    groups = Array(LockerBankAndLockerGroup).from_json releezme.section_banks_allocatable(section_id, user_id).get.to_json
    group = groups.find { |group| group.locker_bank.id == bank_id }
    raise "there are no lockers available to the user in the selected locker bank" unless group
    group.locker_group.id
  end

  protected def get_user_key(user_id)
    return user_id.downcase if @user_id_key == "email" && user_id.includes?("@")
    user = staff_api.user(user_id).get
    user[@user_id_key].as_s
  end

  # allocates a locker now, the allocation may expire
  @[Security(Level::Administrator)]
  def locker_allocate(
    # PlaceOS user id, recommend using email
    user_id : String,

    # the locker location
    bank_id : String | Int64,

    # allocates a random locker if this is nil
    locker_id : String | Int64? = nil,

    # attempts to create a booking that expires at the time specified
    expires_at : Int64? = nil
  ) : PlaceLocker
    user_id = get_user_key(user_id)
    locker_id = locker_id ? lookup_id(locker_id.to_s) : nil

    if expires_at
      timezone = system.timezone || "UTC"
      booking = if locker_id
                  releezme.book_locker(1.minute.ago.to_unix, expires_at, user_id, locker_id, timezone: timezone).get
                else
                  group_id = get_group_id(user_id, bank_id)
                  releezme.book_locker(1.minute.ago.to_unix, expires_at, user_id, group_id: group_id, bank_id: bank_id, timezone: timezone).get
                end
      PlaceLocker.new(Vecos::Booking.from_json booking.to_json)
    elsif locker_id
      vlocker = Vecos::Locker.from_json releezme.locker_allocate(locker_id, user_id).get.to_json
      PlaceLocker.new(vlocker, true)
    else
      group_id = get_group_id(user_id, bank_id)
      vlocker = Vecos::Locker.from_json releezme.locker_allocate_random(bank_id, group_id, user_id).get.to_json
      PlaceLocker.new(vlocker, true)
    end
  end

  # return the locker to the pool
  @[Security(Level::Administrator)]
  def locker_release(
    bank_id : String | Int64,
    locker_id : String | Int64,

    # release / unshare just this user - otherwise release the whole locker
    owner_id : String? = nil
  ) : Nil
    locker_id = lookup_id(locker_id.to_s)
    owner_id = get_user_key(owner_id) if owner_id
    releezme.locker_release(locker_id, owner_id).get
  end

  # a list of lockers that are allocated to the user
  @[Security(Level::Administrator)]
  def lockers_allocated_to(user_id : String) : Array(PlaceLocker)
    user_id = get_user_key user_id
    lockers = Array(Vecos::Locker).from_json releezme.lockers_allocated_to(user_id).get.to_json
    lockers.map { |locker| PlaceLocker.new(locker, true) }
  end

  @[Security(Level::Administrator)]
  def locker_share(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String,
    share_with : String
  ) : Nil
    locker_id = lookup_id(locker_id.to_s)
    releezme.share_locker_with(locker_id, get_user_key(owner_id), get_user_key(share_with)).get
  end

  @[Security(Level::Administrator)]
  def locker_unshare(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String,
    # the individual you previously shared with
    shared_with_id : String? = nil
  ) : Nil
    owner_id = get_user_key(owner_id)
    locker_id = lookup_id(locker_id.to_s)

    # we need the internal id if we want to unshare an individual
    if shared_with_id
      shared_with_external_id = get_user_key(shared_with_id)
      shared_with = Array(Vecos::LockerUsers).from_json releezme.locker_shared_with?(locker_id, owner_id).get.to_json
      shared_user = shared_with.find { |user| user.user_id == shared_with_external_id }
      return unless shared_user
      shared_with_id = shared_user.id
    end
    releezme.unshare_locker(locker_id, owner_id, shared_with_id).get
  end

  # a list of user-ids that the locker is shared with.
  # this can be placeos user ids or emails
  @[Security(Level::Administrator)]
  def locker_shared_with(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String
  ) : Array(String)
    owner_id = get_user_key(owner_id)
    locker_id = lookup_id(locker_id.to_s)
    shared_with = Array(Vecos::LockerUsers).from_json releezme.locker_shared_with?(locker_id, owner_id).get.to_json
    shared_with.map { |user| user.email || user.user_id }
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
    locker_id = lookup_id(locker_id.to_s)
    releezme.locker_unlock(locker_id, pin_code).get
  end

  # ========================================
  # Locatable Interface
  # ========================================

  # array of devices and their x, y coordinates, that are associated with this user
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "releezme incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  # return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "releezme incapable of tracking #{email} or #{username}" }
    [] of String
  end

  # return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "releezme incapable of tracking #{mac_address}" }
    nil
  end

  # array of lockers on this level
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching for lockers in zone #{zone_id}" }

    if building_id == zone_id
      return @zone_filter.flat_map { |level_id| device_locations(level_id, location) }
    end
    return [] of Nil unless @zone_filter.includes?(zone_id)

    # grab all the lockers for the current zone_id
    releexme_section_id = @floor_mappings[zone_id]
    banks = Array(Vecos::LockerBank).from_json releezme.section_locker_banks(releexme_section_id).get.to_json

    if @door_number_lookup && @last_mapped < 3.hour.ago
      # periodically save the locker name => id mappings in redis
      @last_mapped = Time.utc
      banks.flat_map do |bank|
        lockers = Array(Vecos::Locker).from_json releezme.bank_lockers(bank.id).get.to_json
        lockers.map do |locker|
          self[locker.full_door_number.downcase] = locker.id
          PlaceLocker.new(locker, building: building_id, level: zone_id)
        end
      end
    else
      banks.flat_map do |bank|
        lockers = Array(Vecos::Locker).from_json releezme.bank_lockers(bank.id).get.to_json
        lockers.map { |locker| PlaceLocker.new(locker, building: building_id, level: zone_id) }
      end
    end
  end
end
