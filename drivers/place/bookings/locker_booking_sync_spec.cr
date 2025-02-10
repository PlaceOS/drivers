require "placeos-driver/spec"
require "placeos-driver/interface/lockers"
require "../booking_model"
require "./locker_models"

DriverSpecs.mock_driver "Place::Bookings::LockerBookingSync" do
  system({
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
    Lockers:          {LockersMock},
  })

  # Ensure sync works and creates no bookings
  puts "\n\nEMPTY SYNC\n"
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  staff_api = system(:StaffAPI).as(StaffAPIMock)
  staff_api.created.should eq 0
  staff_api.query_calls.should eq 2
  staff_api.reset

  # create a staff api booking as a locker booking has been made
  puts "\n\nLOCKER ALLOCATION SYNC\n"
  lockers = system(:Lockers).as(LockersMock)
  lockers.locker_allocate("user-1", "bank-1", "locker-2")
  lockers.total_lockers_allocated.should eq 1
  staff_api.bookings.size.should eq 0
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  staff_api.bookings.size.should eq 1
  staff_api.created.should eq 1
  staff_api.query_calls.should eq 2
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 1
  staff_api.bookings.size.should eq 1
  staff_api.created.should eq 1
  staff_api.checked_out.should eq 0
  staff_api.updated.should eq 0
  staff_api.query_calls.should eq 4

  # create a locker allocation if a staff API booking has been made
  puts "\n\nSTAFF API BOOKING SYNC\n"
  timezone = Time::Location.load("Australia/Sydney")
  now = Time.local(timezone)
  staff_api.create_booking(
    booking_type: "locker",
    asset_id: "locker-1",
    user_id: "user-2",
    user_email: "user-2@email.com",
    user_name: "User 2",
    zones: ["zone-level1", "zone-1234"],
    booking_start: now.to_unix,
    booking_end: now.at_end_of_day.to_unix,
    title: "Lock 2",
    time_zone: "Australia/Sydney"
  )
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  lockers.total_lockers_allocated.should eq 1
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 2
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 0
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 6
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 2
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 0
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 8

  # release a locker if a staff api booking is ended
  puts "\n\nSTAFF BOOKING ENDED SYNC\n"
  booking = staff_api.bookings.values.find! { |book| book.user_id == "user-2" }
  booking.checked_in = false
  booking.checked_out_at = Time.utc.to_unix
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 1
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 0
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 10
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 1
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 0
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 12

  # end a booking if a locker is released
  puts "\n\nLOCKER RELEASE SYNC\n"
  lockers.locker_release_mine("bank-1", "locker-2")
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 0
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 1
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 14
  exec :sync_level, "zone-level1"
  sleep 300.milliseconds
  lockers.total_lockers_allocated.should eq 0
  staff_api.bookings.size.should eq 2
  staff_api.created.should eq 2
  staff_api.checked_out.should eq 1
  staff_api.updated.should eq 1
  staff_api.query_calls.should eq 16

  # create a new booking and ensure bookings are stable
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  # always requesting the building zone for timezone info
  def zone(id : String)
    raise "unexpected id #{id.inspect}, expected zone-building-id" unless id == "zone-building-id"
    {
      timezone: "Australia/Sydney",
    }
  end

  def systems_in_building(id : String, ids_only : Bool = true)
    raise "unexpected id #{id.inspect}, expected zone-building-id" unless id == "zone-building-id"
    raise "only ids supported, unexpected call" unless ids_only
    {
      "zone-level1" => [] of String,
      "zone-level2" => [] of String,
    }
  end

  def metadata(id : String, key : String? = nil)
    raise "unexpected building id: #{id}" unless id == "zone-building-id"
    case key
    when "locker_banks"
      {
        locker_banks: {
          details: [
            {
              id:    "bank-1",
              name:  "Bank 1",
              zones: ["zone-building-id", "zone-level1"],
            },
            {
              id:    "bank-2",
              name:  "Bank 2",
              zones: ["zone-building-id", "zone-level2"],
            },
          ],
        },
      }
    when "lockers"
      {
        lockers: {
          details: [
            {
              id:       "locker-1",
              name:     "Lock 1",
              bank_id:  "bank-1",
              bookable: true,
            },
            {
              id:       "locker-2",
              name:     "Lock 2",
              bank_id:  "bank-1",
              bookable: true,
            },
            {
              id:       "locker-3",
              name:     "Lock 3",
              bank_id:  "bank-2",
              bookable: true,
            },
            {
              id:       "locker-4",
              name:     "Lock 4",
              bank_id:  "bank-2",
              bookable: true,
            },
          ],
        },
      }
    else
      {} of Nil => Nil
    end
  end

  def reset
    @query_calls = 0
    @created = 0
    @checked_out = 0
    @updated = 0
    @bookings = {} of Int64 => Place::Booking
  end

  # emulate a basic database
  getter bookings : Hash(Int64, Place::Booking) = {} of Int64 => Place::Booking
  getter query_calls : Int32 = 0
  getter created : Int32 = 0
  getter updated : Int32 = 0
  getter checked_out : Int32 = 0

  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    extension_data : JSON::Any? = nil,
    deleted : Bool? = nil
  )
    @query_calls += 1
    # return the bookings in the database
    # ignore calls to deleted and return an empty array
    return [] of Nil if deleted
    @bookings.values
  end

  def booking_state(booking_id : String | Int64, state : String, instance : Int64? = nil)
    booking = @bookings[booking_id]?
    raise "could not find booking #{booking_id}" unless booking
    @updated += 1
    booking.process_state = state
    booking
  end

  # we won't test with a booking instance here as it jsut complicates things
  # def update_booking

  def booking_check_in(booking_id : String | Int64, state : Bool = true, utm_source : String? = nil, instance : Int64? = nil)
    booking = @bookings[booking_id]?
    raise "could not find booking #{booking_id}" unless booking
    booking.checked_in = state
    booking.checked_out_at = Time.utc.to_unix unless state
    @checked_out += 1 unless state
    booking
  end

  def user(id : String)
    case id
    when "user-1", "user-1@email.com"
      {
        id:    "user-1",
        email: "user-1@email.com",
        name:  "User 1",
      }
    when "user-2", "user-2@email.com"
      {
        id:    "user-2",
        email: "user-2@email.com",
        name:  "User 2",
      }
    else
      raise "unexpected user id requested #{id}"
    end
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    checked_in : Bool = false,
    approved : Bool? = nil,
    title : String? = nil,
    description : String? = nil,
    time_zone : String? = nil,
    extension_data : JSON::Any? = nil,
    utm_source : String? = nil,
    limit_override : Int64? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    attendees : Array(Nil)? = nil,
    process_state : String? = nil,
    recurrence_type : String? = nil,
    recurrence_days : Int32? = nil,
    recurrence_nth_of_month : Int32? = nil,
    recurrence_interval : Int32? = nil,
    recurrence_end : Int64? = nil
  )
    @created += 1
    id = rand(Int64::MAX)
    @bookings[id] = Place::Booking.new(
      id: id,
      booking_type: booking_type,
      asset_id: asset_id,
      user_id: user_id,
      user_email: user_email,
      user_name: user_name,
      zones: zones,
      booked_by_name: user_name,
      booked_by_email: user_email,
      booking_start: booking_start.not_nil!,
      booking_end: booking_end.not_nil!,
      timezone: time_zone.not_nil!,
      process_state: process_state
    )
  end

  def get_booking(booking_id : String | Int64, instance : Int64? = nil)
    # this function shouldn't really be called
    logger.warn { "UNEXPECTED CALL TO staff_api.get_booking(#{booking_id.inspect}, #{instance.inspect})" }
    @bookings[booking_id.to_i]
  end
end

# re-open classes to add some helpers
class ::Place::Locker
  def initialize(@id, @name, @bank_id, @bookable, @level_id)
  end

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

class Place::LockerBank
  def initialize(@id, @name, @zones, @level_id, @lockers)
  end
end

# :nodoc:
class LockersMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Lockers

  alias LockerBank = Place::LockerBank
  alias Locker = Place::Locker

  def reset
    @locker_banks = nil
    @locker_details = nil
  end

  def total_lockers_allocated : Int32
    allocated = 0
    locker_details.each_value do |locker|
      allocated += 1 if locker.allocated?
    end
    allocated
  end

  def invoked_by_user_id
    "user-1"
  end

  # implement the locker metadata parser methods
  getter locker_banks : Hash(String, LockerBank) do
    {
      "bank-1" => LockerBank.new("bank-1", "Bank 1", ["zone-building-id", "zone-level1"], "zone-level1", [
        Locker.new("locker-1", "Lock 1", "bank-1", true, "zone-level1"),
        Locker.new("locker-2", "Lock 2", "bank-1", true, "zone-level1"),
      ]),
      "bank-2" => LockerBank.new("bank-2", "Bank 2", ["zone-building-id", "zone-level2"], "zone-level2", [
        Locker.new("locker-3", "Lock 3", "bank-2", true, "zone-level2"),
        Locker.new("locker-4", "Lock 4", "bank-2", true, "zone-level2"),
      ]),
    }
  end

  getter locker_details : Hash(String, Locker) do
    lockers = {} of String => Locker
    locker_banks.each_value do |bank|
      bank.lockers.each do |locker|
        lockers[locker.id] = locker
      end
    end
    lockers
  end

  def building_id : String
    "zone-building-id"
  end

  def levels : Array(String)
    ["zone-level1", "zone-level2"]
  end

  # allocates a locker now, the allocation may expire
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

  USER_EMAILS = {
    "user-1" => "user-1@email.com",
    "user-2" => "user-2@email.com",
  }

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
        assigned_to: USER_EMAILS[locker.allocated_to],
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

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def building_id : String
    "zone-building-id"
  end
end
