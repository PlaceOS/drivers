require "placeos-driver"
require "placeos-driver/interface/lockers"
require "../bookings/locker_models"

class Place::Demo::Lockers < PlaceOS::Driver
  include Interface::Lockers
  include Place::LockerMetadataParser
  alias PlaceLocker = PlaceOS::Driver::Interface::Lockers::PlaceLocker

  descriptive_name "Locker Testing"
  generic_name :DemoLockers
  description %(used for end to end testing of locker interfaces)

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  getter building_id : String do
    locations.building_id.get.as_s
  end

  getter levels : Array(String) do
    staff_api.systems_in_building(building_id).get.as_h.keys
  end

  # re-open class to add some helpers
  class ::Place::Locker
    # for tracking, not part of metadata
    property allocated_to : String? = nil
    property allocated_at : Time? = nil
    property allocated_until : Time? = nil
    property shared_with : Array(String) = [] of String

    def release
      @allocated_to = nil
      @allocated_at = nil
      @allocated_until = nil
      @shared_with = [] of String
    end

    def allocated? : Bool
      if time = self.allocated_until
        if time > Time.utc
          true
        else
          false
        end
      elsif self.allocated_to.presence
        true
      else
        false
      end
    end

    def not_allocated? : Bool
      !allocated?
    end
  end

  class ::PlaceOS::Driver::Interface::Lockers::PlaceLocker
    def initialize(@bank_id, locker : ::Place::Locker, @building = nil)
      @locker_id = locker.id
      @locker_name = locker.name
      @mac = "lb=#{@bank_id}&lk=#{locker.id}"
      if time = locker.allocated_until
        if time > Time.utc
          in_use = true
          @expires_at = time
        else
          in_use = false
          @expires_at = nil
        end
      elsif allocated_to = locker.allocated_to
        in_use = true
        @expires_at = nil
      else
        in_use = false
        @expires_at = nil
      end
      @allocated = in_use
      @allocation_id = "#{locker.allocated_to}--#{locker.id}--#{locker.allocated_at.try(&.to_unix_ns)}" if in_use
      @level = locker.level_id
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
    bank = locker_banks[bank_id.to_s]
    locker_id = locker_id ? locker_id : bank.locker_hash.values.select(&.not_allocated?).sample.id
    locker = bank.locker_hash[locker_id.to_s]
    locker.allocated_to = user_id
    locker.allocated_at = Time.utc
    locker.allocated_until = Time.unix(expires_at) if expires_at
    PlaceLocker.new(bank_id, locker, building_id)
  rescue
    raise "no available lockers"
  end

  # return the locker to the pool
  @[Security(Level::Administrator)]
  def locker_release(
    bank_id : String | Int64,
    locker_id : String | Int64,

    # release / unshare just this user - otherwise release the whole locker
    owner_id : String? = nil
  ) : Nil
    locker = locker_banks[bank_id.to_s].locker_hash[locker_id.to_s]
    if locker.allocated_to == owner_id
      locker.release
    else
      locker.shared_with.delete(owner_id)
    end
  end

  # a list of lockers that are allocated to the user
  @[Security(Level::Administrator)]
  def lockers_allocated_to(user_id : String) : Array(PlaceLocker)
    now = Time.utc
    building = building_id

    locker_banks.values.flat_map do |bank|
      bank.locker_hash.values.compact_map do |locker|
        if locker.allocated_to == user_id
          if time = locker.allocated_until
            PlaceLocker.new(bank.id, locker, building) if time > now
          else
            PlaceLocker.new(bank.id, locker, building)
          end
        end
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
    locker = locker_banks[bank_id.to_s].locker_hash[locker_id.to_s]
    perform_share = false
    if locker.allocated_to == owner_id
      if time = locker.allocated_until
        perform_share = time > Time.utc
      else
        perform_share = true
      end
    end

    if perform_share
      locker.shared_with << share_with
      locker.shared_with.uniq!
    end
  end

  @[Security(Level::Administrator)]
  def locker_unshare(
    bank_id : String | Int64,
    locker_id : String | Int64,
    owner_id : String,
    # the individual you previously shared with (optional)
    shared_with_id : String? = nil
  ) : Nil
    locker = locker_banks[bank_id.to_s].locker_hash[locker_id.to_s]
    perform_share = false
    if locker.allocated_to == owner_id
      if time = locker.allocated_until
        perform_share = time > Time.utc
      else
        perform_share = true
      end
    end

    if perform_share
      if shared_with_id
        locker.shared_with.delete shared_with_id
      else
        locker.shared_with = [] of String
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
    locker = locker_banks[bank_id.to_s].locker_hash[locker_id.to_s]
    perform_share = false
    if locker.allocated_to == owner_id
      if time = locker.allocated_until
        perform_share = time > Time.utc
      else
        perform_share = true
      end
    end

    if perform_share
      locker.shared_with
    else
      [] of String
    end
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
    # "lb=#{@bank_id}&lk=#{locker.id}"
    return nil unless mac_address.starts_with?("lb=")
    floor_mac = URI::Params.parse mac_address
    locker_bank = floor_mac["lb"]
    locker_key = floor_mac["lk"]
    locker = locker_banks[locker_bank].locker_hash[locker_key]

    has_reservation = false
    if user_id = locker.allocated_to
      if time = locker.allocated_until
        has_reservation = time > Time.utc
      else
        has_reservation = true
      end
    end

    if has_reservation
      {
        location:    "locker",
        assigned_to: staff_api.user(locker.allocated_to).get["email"].as_s,
        mac_address: mac_address,
      }
    end
  rescue
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching lockers in zone #{zone_id}" }
    return [] of Nil if location && location != "locker"

    building = building_id
    level_zone = zone_id == building ? nil : zone_id
    return [] of Nil if level_zone && !level_zone.in?(levels)

    now = Time.utc
    locker_banks.values.flat_map do |bank|
      next [] of PlaceLocker if level_zone && bank.level_id != level_zone

      bank.locker_hash.values.compact_map do |locker|
        if locker.allocated_to
          if time = locker.allocated_until
            PlaceLocker.new(bank.id, locker, building) if time > now
          else
            PlaceLocker.new(bank.id, locker, building)
          end
        end
      end
    end
  end
end
