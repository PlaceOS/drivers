require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "placeos-driver/interface/zone_access_security"
require "../booking_model"

class Place::Bookings::GrantAreaAccess < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Booking Area Access"
  generic_name :BookingAreaAccess
  description "ensures users can access areas they have booked. i.e. a private office allocated to a user"

  default_settings({
    # the channel id we're looking for events on
    lookup_using_username:    true,
    _security_zone_whitelist: ["zone_name_or_id"],

    # At 10:00 on every day-of-week from Monday through Friday
    _email_cron:      "0 10 * * 1-5",
    _email_errors_to: "admin@org.com",
  })

  accessor calendar : Calendar_1
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

    on_update
  end

  @mutex = Mutex.new

  # user_id => Array(special access)
  getter allocations : Hash(String, Array(String)) = {} of String => Array(String)
  getter cached_username : Hash(String, String) = {} of String => String
  getter cached_user_lookups : Hash(String, String | Int64) = {} of String => String | Int64
  getter cached_zone_lookups : Hash(String, String | Int64) = {} of String => String | Int64
  getter security_zone_whitelist : Array(String | Int64) = [] of String | Int64

  @lookup_using_username : Bool = false
  @email_errors_to : String? = nil

  def on_update
    @building_id = nil
    @timezone = nil
    @systems = nil

    @lookup_using_username = setting?(Bool, :lookup_using_username) || false
    @security_zone_whitelist = setting?(Array(String | Int64), :security_zone_whitelist) || [] of String | Int64

    # we ensure that allocations are recorded so we can unallocate as required
    @mutex.synchronize do
      @allocations = setting?(Hash(String, Array(String)), :permissions_allocated) || Hash(String, Array(String)).new
    end

    schedule.clear
    schedule.every(30.minutes) { ensure_booking_access }

    @email_errors_to = setting?(String, :email_errors_to)
    if @email_errors_to && (cron = setting?(String, :email_cron))
      schedule.cron(cron, timezone) { notify_issues }
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

  def username_lookup(email : String) : String
    email = email.strip.downcase
    if username = cached_username[email]?
      username
    else
      username = calendar.get_user(email).get["username"]?.try(&.as_s.downcase) || email
      if username == email
        cached_username[email] = email
      else
        cached_username[email] = username
      end
      username
    end
  end

  def user_id?(email : String) : String | Int64 | Nil
    security = security_system
    lookup_user_id security, email.downcase
  end

  protected def lookup_user_id(security, email : String) : String | Int64 | Nil
    id = cached_user_lookups[email]?
    return id if id

    if @lookup_using_username && (username = username_lookup(email))
      json = (security.card_holder_id_lookup(username).get rescue nil)
      if json && json.raw
        id = (String | Int64).from_json(json.to_json)
        cached_user_lookups[email] = (String | Int64).from_json(json.to_json)
        return id
      end
    end

    # handle the case where we have a json `null` response
    json = (security.card_holder_id_lookup(email).get rescue nil)
    if json && json.raw
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
    id_raw = security.zone_access_id_lookup(name_or_id).get
    if id = id_raw.as_s? || id_raw.as_i64?
      cached_zone_lookups[name_or_id] = id
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
  def desks(level_id : String, blocked : Hash(String, String | Int64) = {} of String => String | Int64) : Hash(String, String)
    desks = staff_api.metadata(level_id, "desks").get.dig?("desks", "details")
    security = {} of String => String
    return security unless desks

    Array(Desk).from_json(desks.to_json).each do |desk|
      sec = desk.security.presence
      next unless sec

      if security_zone_whitelist.empty?
        security[desk.id] = sec
      elsif security_zone_whitelist.includes?(sec)
        security[desk.id] = sec
      else
        blocked[desk.id] = sec
      end
    end
    security
  end

  protected def has_access?(security, zone_id, user_id) : Bool
    has_access = (String | Int64 | Nil).from_json(security.zone_access_member?(zone_id, user_id).get.to_json)
    !!has_access
  end

  @check_mutex : Mutex = Mutex.new
  @performing_check : Bool = false
  @check_queued : Bool = false

  def ensure_booking_access
    errors = [] of String
    # desk id => security zone
    # where mapping blocked due to not being whitelisted
    blocked = {} of String => String | Int64

    @check_mutex.synchronize do
      if @performing_check
        @check_queued = true
        return
      end

      @performing_check = true
      @check_queued = false
    end

    @mutex.synchronize do
      now = Time.local(timezone).at_beginning_of_day
      end_of_day = 3.days.from_now.in(timezone).at_end_of_day

      access_required = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

      # calculate who needs access
      levels.each do |level_id|
        desks = desks(level_id, blocked)
        next if desks.empty?

        desk_bookings = staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {level_id}, type: "desk").get.as_a
        next if desk_bookings.empty?

        desk_bookings.each do |booking|
          desk = booking["asset_id"].as_s
          if security = desks[desk]?
            user_access = access_required[booking["user_email"].as_s.downcase]
            user_access << security
            user_access.uniq!
          end
        end
      end

      # apply access this access to the system, need to find the differences
      allocations = @allocations
      logger.debug { "found #{access_required.size} users that need access" }

      if allocations == access_required
        logger.debug { "no access changes are required" }
        return
      end

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

      logger.debug { "deleting permissions: #{remove.size}" }
      logger.debug { "granting permissions: #{add.size}" }

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
              security.zone_access_remove_member(zone_id, user_id).get if has_access?(security, zone_id, user_id)
            rescue error
              # add the user back to the zone so it can be removed in a later sync
              access_required[user_email] << zone
              msg = "failed to remove #{user_email} from security zone: #{zone}"
              errors << msg
              logger.warn(exception: error) { msg }
            end
          end
        rescue error
          access_required[user_email] = allocations[user_email]
          add.delete(user_email)
          msg = "failed to remove #{user_email} from security zones"
          errors << msg
          logger.warn(exception: error) { msg }
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
              security.zone_access_add_member(zone_id, user_id).get unless has_access?(security, zone_id, user_id)
            rescue error
              # remove the user from the recorded zone so it can be added in a later sync
              access_required[user_email].delete zone
              msg = "failed to add #{user_email} to security zone: #{zone}"
              errors << msg
              logger.warn(exception: error) { msg }
            end
          end
        rescue error
          access_required.delete(user_email)
          msg = "failed to add #{user_email} to security zones"
          errors << msg
          logger.warn(exception: error) { msg }
        end
      end

      # save the newly applied access permissions
      define_setting(:permissions_allocated, access_required)
    ensure
      @check_mutex.synchronize do
        @performing_check = false
        spawn { ensure_booking_access } if @check_queued
      end
    end

    # expose errors and anything blocked as not on the whitelist
    self[:sync_errors] = errors
    self[:sync_blocked] = blocked
  end

  @[Security(Level::Support)]
  def security_zone_report
    # desk id => security id
    blocked = {} of String => String | Int64
    found = {} of String => String | Int64
    levels.each do |level_id|
      found.merge! desks(level_id, blocked)
    end

    found_values = found.values.map(&.to_s).uniq!
    security_groups = found.values + blocked.values
    in_whitelist_only = security_zone_whitelist - security_groups

    {
      blocked:           blocked,
      allocated:         found_values,
      in_whitelist_only: in_whitelist_only,
    }
  end

  @[Security(Level::Support)]
  def approve_security_zone_list
    # save all the security zones to the whitelist
    details = security_zone_report
    new_whitelist = details[:in_whitelist_only] + details[:allocated] + details[:blocked].values.uniq!
    whitelist_strings = new_whitelist.compact_map { |item| item.as(String) if item.is_a?(String) }.sort!
    whitelist_ints = new_whitelist.compact_map { |item| item.as(Int64) if item.is_a?(Int64) }.sort!

    new_whitelist = [] of String | Int64
    new_whitelist.concat whitelist_strings
    new_whitelist.concat whitelist_ints

    define_setting(:security_zone_whitelist, new_whitelist)
    new_whitelist
  end

  # =========================
  # MailerTemplates interface
  # =========================

  def template_fields : Array(TemplateFields)
    [
      TemplateFields.new(
        trigger: {"security", "area_access_errors"},
        name: "Booking Area Access Errors",
        description: "Email sent when there are errors adding users to security groups so they can access the desk they have booked or allocated",
        fields: [
          {name: "errors", description: "a formatted list of email addresses to security groups that could not be applied"},
          {name: "system_id", description: "the system with the BookingAreaAccess driver"},
        ]
      ),
    ]
  end

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def notify_issues
    sync_blocked = status?(Hash(String, String | Int64), :sync_blocked) || Hash(String, String | Int64).new
    sync_errors = status?(Array(String), :sync_errors) || [] of String
    return if sync_blocked.empty? && sync_errors.empty?

    issue_list = String.build do |io|
      if !sync_blocked.empty?
        io << "security groups not in the whitelist: <br>\n"
        io << "===================================== <br>\n"

        sync_blocked.each do |desk_id, security_zone|
          io << "desk: #{desk_id}, security group: #{security_zone} <br>\n"
        end
        io << " <br><br>\n\n"
      end

      if !sync_errors.empty?
        io << "unable to allocate desks for: <br>\n"
        io << "============================= <br>\n"

        sync_errors.each do |error|
          io << " - "
          io << error
          io << " <br>\n"
        end
        io << " <br><br>\n\n"
      end
    end

    mailer.send_template(@email_errors_to.as(String), {"security", "area_access_errors"}, {
      errors:    issue_list,
      system_id: config.control_system.try(&.id),
    })
  end
end
