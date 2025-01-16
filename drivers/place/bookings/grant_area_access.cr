require "placeos-driver"
require "placeos-driver/interface/zone_access_security"
require "../booking_model"

class Place::Bookings::GrantAreaAccess < PlaceOS::Driver
  descriptive_name "PlaceOS Booking Area Access"
  generic_name :BookingAreaAccess
  description "ensures users can access areas they have booked. i.e. a private office allocated to a user etc"

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  def security_system
    system.implementing(Interface::ZoneAccessSecurity).first
  end

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      check_access(Booking.from_json payload)
    end

    schedule.every(30.minutes) { ensure_booking_access }
  end

  @mutex = Mutex.new

  # user_id => Array(special access)
  getter allocations : Hash(String, Array(String)) = {} of String => Array(String)
  getter cached_user_lookups : Hash(String, String | Int64) = {} of String => String | Int64
  getter cached_zone_lookups : Hash(String, String | Int64) = {} of String => String | Int64

  def on_update
    @building_id = nil
    @timezone = nil
    @systems = nil

    # we ensure that allocations are recorded so we can unallocate as required
    @mutex.synchronize do
      @allocations = setting?(Hash(String, Array(String)), :permissions_allocated) || Hash(String, Array(String)).new
    end
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  # Grabs the list of systems in the building
  getter systems : Hash(String, Array(String)) do
    staff_api.systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  end

  def levels : Array(String)
    systems.keys
  end

  # system or building timezone
  protected getter timezone : Time::Location do
    tz = config.control_system.try(&.timezone) || staff_api.zone(building_id).get["timezone"].as_s
    Time::Location.load(tz)
  end

  protected def check_access(booking : Booking)
    now = Time.local(timezone)
    end_of_day = now.at_end_of_day

    return unless booking.booking_start <= end_of_day.to_unix && booking.booking_end >= now.to_unix
    ensure_booking_access
  end

  struct Desk
    include JSON::Serializable

    getter id : String
    getter security : String? = nil
  end

  def user_id?(email : String) : String | Int64 | Nil
    security = security_system
    lookup_user_id security, email.downcase
  end

  protected def lookup_user_id(security, email : String) : String | Int64 | Nil
    id = cached_user_lookups[email]?
    return id if id

    if json = (security.card_holder_id_lookup(email).get rescue nil)
      cached_user_lookups[email] = (String | Int64).from_json(json.to_json)
    end
  end

  def zone_id?(name_or_id : String) : String | Int64 | Nil
    security = security_system
    lookup_zone_id security, name_or_id
  end

  protected def lookup_zone_id(security, name_or_id : String) : String | Int64 | Nil
    id = cached_zone_lookups[name_or_id]?
    return id if id

    # check if this was a name and lookup the id
    if id = security.zone_access_id_lookup(name_or_id).get
      id = cached_zone_lookups[name_or_id] = (String | Int64).from_json(id.to_json)
      return id
    end

    # check if the ID was passed directly
    if (security.zone_access_lookup(name_or_id).get rescue nil)
      cached_zone_lookups[name_or_id] = name_or_id
      return name_or_id
    end

    # otherwise the id or name is probably incorrect
    logger.warn { "Zone lookup failed for: #{name_or_id}" }
    nil
  end

  # returns desk_id => security zone name / id
  def desks(level_id : String) : Hash(String, String)
    desks = staff_api.metadata(building_id, "desks").get.dig?("desks", "details")
    security = {} of String => String
    return security unless desks

    Array(Desk).from_json(desks.to_json).each do |desk|
      sec = desk.security
      next unless sec && sec.presence
      security[desk.id] = sec
    end
    security
  end

  def ensure_booking_access
    @mutex.synchronize do
      now = Time.local(timezone)
      end_of_day = now.at_end_of_day

      access_required = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

      # calculate who needs access
      levels.each do |level_id|
        desk_bookings = staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {level_id}, type: "desk").get.as_a
        next if desk_bookings.empty?
        desks = desks(level_id)

        desk_bookings.each do |booking|
          desk = booking["asset_id"].as_s
          if security = desks[desk]?
            access_required[booking["user_email"].as_s.downcase] << security
          end
        end
      end

      # apply access this access to the system, need to find the differences
      allocations = @allocations
      return if allocations == access_required

      remove = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      add = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

      # Collect all keys from both hashes
      all_keys = allocations.keys.concat(access_required.keys)
      all_keys.each do |key|
        current = allocations[key]? || [] of String
        desired = access_required[key]? || [] of String

        # Calculate elements to remove and add
        to_remove = current - desired
        to_add = desired - current

        # Add to `remove` hash if there are elements to remove
        remove[key] = to_remove unless to_remove.empty?

        # Add to `add` hash if there are elements to add
        add[key] = to_add unless to_add.empty?
      end

      # apply the differences
      security = security_system
      remove.each do |user_email, zones|
        begin
          user_id = lookup_user_id(security, user_email)
          raise "unable to find user_id for: #{user_email}" unless user_id

          zones.uniq!.each do |zone|
            begin
              zone_id = lookup_zone_id(security, zone)
              raise "unable to find zone_id for: #{zone}" unless zone_id
              security.zone_access_remove_member(zone_id, user_id).get
            rescue error
              # add the user back to the zone so it can be removed in a later sync
              access_required[user_email] << zone
              logger.warn(exception: error) { "failed to remove #{user_email} from security zone: #{zone}" }
            end
          end
        rescue error
          access_required[user_email] = allocations[user_email]
          add.delete(user_email)
          logger.warn(exception: error) { "failed to remove #{user_email} from security zones" }
        end
      end

      add.each do |user_email, zones|
        begin
          user_id = lookup_user_id(security, user_email)
          raise "unable to find user_id for: #{user_email}" unless user_id

          zones.uniq!.each do |zone|
            begin
              zone_id = lookup_zone_id(security, zone)
              raise "unable to find zone_id for: #{zone}" unless zone_id
              security.zone_access_add_member(zone_id, user_id).get
            rescue error
              # remove the user from the recorded zone so it can be added in a later sync
              access_required[user_email].delete zone
              logger.warn(exception: error) { "failed to add #{user_email} to security zone: #{zone}" }
            end
          end
        rescue error
          access_required.delete(user_email)
          logger.warn(exception: error) { "failed to add #{user_email} to security zones" }
        end
      end

      # save the newly applied access permissions
      define_setting(:permissions_allocated, access_required)
    end
  end
end
