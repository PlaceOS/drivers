require "placeos-driver"
require "simple_retry"

class Gallagher::ZoneSchedule < PlaceOS::Driver
  descriptive_name "Gallagher Zone Schedule"
  generic_name :GallagherZoneSchedule
  description "maps a booking state to a gallagher access zone state"

  accessor bookings : Bookings_1

  default_settings({
    # gallagher_system: "sys-12345"
    zone_id:          "1234",
    _access_group_id: "140623",

    # booking status => zone state
    state_mappings: {
      "pending" => "free",
      "busy"    => "free",
      "free"    => "default",
    },

    # max time in minutes that presence can prevent a lock.
    presence_timeout:   30,
    grant_hosts_access: false,

    disable_unlock: {
      keys:  ["extended_properties", "Don't Unlock"],
      value: "TRUE",
    },
  })

  struct DisableUnlock
    include JSON::Serializable

    getter keys : Array(String)
    getter value : String
  end

  getter system_id : String = ""
  getter count : UInt64 = 0_u64

  # Tracking meeting details
  getter zone_id : String | Int64 = ""
  getter state_mappings : Hash(String, String) = {} of String => String

  @update_mutex = Mutex.new
  @disable_unlock : DisableUnlock? = nil

  def on_update
    @system_id = setting?(String, :gallagher_system).presence || config.control_system.not_nil!.id
    @state_mappings = setting(Hash(String, String), :state_mappings)
    @zone_id = setting?(String | Int64, :zone_id) || setting(String | Int64, :door_zone_id)
    @presence_timeout = (setting?(Int32, :presence_timeout) || 30).minutes
    @access_group_id = nil

    @grant_hosts_access = setting?(Bool, :grant_hosts_access) || false
    @host_access_mutex.synchronize do
      @access_granted = setting?(Hash(String, String | Int64), :access_granted) || {} of String => String | Int64
    end

    # restore tracked meeting-driven security group access from the persisted
    # setting so we know which users we've granted access to across restarts
    @meeting_security_mutex.synchronize do
      @meeting_security_access = setting?(Hash(String, Hash(String, String | Int64)), :meeting_security_access) || {} of String => Hash(String, String | Int64)
    end
    @cached_zone_lookups = {} of String => String | Int64
    @cached_cardholder_lookups = {} of String => String | Int64

    @disable_unlock = setting?(DisableUnlock, :disable_unlock) rescue nil
    # @current_state = setting?(String, :saved_current_state)
  end

  bind Bookings_1, :status, :status_changed
  bind Bookings_1, :presence, :presence_changed

  getter last_status : String? = nil
  getter last_presence : Bool? = nil
  getter grant_hosts_access : Bool = false

  @current_state : String? = nil

  getter access_group_id : String | Int64 do
    setting?(String | Int64, :access_group_id) || find_access_group_from_zone
  end

  @presence_relevant : Bool = false
  @presence_timeout : Time::Span = 30.minutes

  private def status_changed(_subscription, new_value)
    logger.debug { "new room status: #{new_value}" }
    new_status = (String?).from_json(new_value) rescue new_value.to_s
    @last_status = new_status
    @update_mutex.synchronize { apply_new_state(new_status, @last_presence) }
  end

  private def presence_changed(_subscription, new_value)
    logger.debug { "new room status: #{new_value}" }
    new_presence = (Bool?).from_json(new_value) rescue nil
    @last_presence = new_presence
    @update_mutex.synchronize { apply_new_state(@last_status, new_presence) }
  end

  private def apply_new_state(new_status : String?, presence : Bool?)
    logger.debug { "#apply_new_state called with new_status: #{new_status}" }

    # we'll ignore nil values, most likely only when drivers are updated or starting
    return unless new_status

    # check if we want to disable unlock for this booking
    unlock_disabled = !should_unlock_booking?
    if unlock_disabled
      new_status = "free"
      @presence_relevant = false
    end

    # ignore redis errors as this is a critical system component
    begin
      self[:unlock_disabled] = unlock_disabled
      self[:booking_status] = new_status
      self[:people_present] = presence
    rescue
    end

    apply_zone_state = state_mappings[new_status]?
    if apply_zone_state.nil?
      logger.debug { "no mapping for booking status #{new_status}, ignoring" }
      return
    end

    schedule.clear

    # This is checking if want to lock the room (not free)
    # and if someone is present and presence matters
    # then change zone state to unlock
    if apply_zone_state == "free"
      @presence_relevant = true
    elsif presence && @presence_relevant
      apply_zone_state = "free"
      @presence_relevant = false
      schedule.in(@presence_timeout) do
        @update_mutex.synchronize { apply_new_state(@last_status, @last_presence) }
      end
    end

    self[:zone_state] = apply_zone_state rescue nil

    if apply_zone_state != @current_state
      logger.debug { "mapping #{new_status} => #{apply_zone_state} in #{zone_id}" }

      begin
        SimpleRetry.try_to(
          max_attempts: 5,
          base_interval: 500.milliseconds,
          max_interval: 1.seconds,
          randomise: 100.milliseconds
        ) do
          case apply_zone_state
          when "free"
            gallagher.free_zone(zone_id).get
          when "secure"
            gallagher.secure_zone(zone_id).get
          when "default", "reset"
            gallagher.reset_zone(zone_id).get
          else
            logger.warn { "unknown zone state #{apply_zone_state}" }
            false
          end
        end
        @count += 1
      rescue error
        self[:last_error] = {
          message: error.message,
          at:      Time.utc.to_s,
        }
      end

      @current_state = apply_zone_state
      # @host_access_mutex.synchronize do
      #   define_setting(:saved_current_state, apply_zone_state) rescue nil
      # end
    else
      logger.debug { "zone state already applied, skipping step" }
    end

    schedule.in(1.second) { check_host_access } if @grant_hosts_access

    # reconcile additional security group access (control_system.security_groups)
    # for the meeting host whenever the room status transitions
    schedule.in(1.second) { reconcile_meeting_security_group_access }
  end

  private def gallagher
    system(system_id)["Gallagher"]
  end

  # ==========================================
  # check if the current booking should unlock
  # ==========================================

  def should_unlock_booking? : Bool
    # do we need to check if the room should unlock
    disable_unlock = @disable_unlock
    if disable_unlock.nil?
      logger.debug { "unlock check disabled" }
      return true
    end

    # if so we need to grab the current bookings
    booking_mod = bookings
    current_booking = booking_mod[:current_booking]?
    if current_booking.nil? && booking_mod.status?(Bool, :pending)
      logger.debug { "looking at next_booking as current_booking has not started" }
      current_booking = booking_mod[:next_booking]?
    end

    if current_booking.nil?
      logger.debug { "ignoring as no booking found" }
      return true
    end

    # check if the booking should allow unlocking or not
    value = current_booking
    disable_unlock.keys.each do |key|
      value = value[key]?
      break if value.nil?
    end

    if value.nil?
      logger.debug { "could not find relevant key, ignoring" }
      return true
    end

    result = !(value.as_s? == disable_unlock.value)
    logger.debug { "checking #{value.as_s?.inspect} == #{disable_unlock.value.inspect} (#{!result})" }
    result
  rescue error
    logger.error(exception: error) { "error checking if a room should not be unlocked" }
    self[:last_error] = {
      message: error.message,
      at:      Time.utc.to_s,
    }
    true
  end

  # ============================================
  # Grant host access to space for locking doors
  # ============================================

  def find_access_group_from_zone : String
    gal = gallagher
    zone_name = gal.get_access_zone(zone_id).get["name"].as_s
    gal.get_access_groups(zone_name).get.as_a.first["id"].as_s
  end

  # we want to do this as the local Calendar module may
  # not be a graph or google calendar (which we need)
  private def calendar
    system(system_id)["Calendar"]
  end

  # email => cardholder_id
  getter access_granted : Hash(String, String | Int64) = {} of String => String | Int64
  getter existing_access : Hash(String, String | Int64) = {} of String => String | Int64

  @host_access_mutex = Mutex.new

  enum Status
    Pending
    Busy
    Free
  end

  def check_host_access
    return unless @grant_hosts_access

    host_email = bookings.status?(String, :host_email).try(&.strip.downcase)
    next_host = bookings.status?(String, :next_host).try(&.strip.downcase)
    status = bookings.status?(Status, :status)

    security = gallagher
    return remove_all_access(security) unless status

    case status
    in .pending?, .busy?
      # should we be removing any access?
      active_hosts = [host_email, next_host].compact
      current_access = access_granted.keys + existing_access.keys
      remove_access = current_access - active_hosts
      remove_access_from security, remove_access

      # do we need to grant access?
      needs_access = active_hosts - current_access
      return if needs_access.empty?

      # tuple: needs access, email, cardholder_id
      access_required = [] of Tuple(Bool, String, String | Int64)
      needs_access.each do |email|
        begin
          # get the users username (for lookup in the security system)
          user = calendar.get_user(email).get
          username = (user["username"]? || user["email"]).as_s.downcase

          # find the user in the security system
          cardholder = security.card_holder_id_lookup(email).get
          cardholder_id = cardholder.as_s? || cardholder.as_i64

          # check if the user already has access
          if (String | Int64 | Nil).from_json(security.zone_access_member?(access_group_id, cardholder_id).get_json)
            access_required << {false, username, cardholder_id}
            next
          end

          # the user needs access
          access_required << {true, username, cardholder_id}
        rescue error
          logger.warn(exception: error) { "failed to grant room access to #{email}" }
          self[:staff_access_error] = {
            message: "failed to grant room access to #{email}",
            error:   error.message,
            at:      Time.utc.to_s,
          }
        end
      end

      grant_access_to security, access_required
    in .free?
      remove_all_access(security)
    end
  end

  protected def remove_all_access(security)
    current_access = access_granted.keys + existing_access.keys
    remove_access_from security, current_access

    # we define the setting here as remove access does not define this setting
    @host_access_mutex.synchronize do
      define_setting(:access_granted, access_granted)
    end
  end

  protected def remove_access_from(security, users : Array(String))
    users.each do |user|
      if cardholder_id = access_granted[user]?
        security.zone_access_remove_member(access_group_id, cardholder_id).get rescue nil
      end
    end

    # update after as no harm removing access again
    @host_access_mutex.synchronize do
      users.each do |user|
        access_granted.delete user
        existing_access.delete user
      end
    end
  rescue error
    logger.error(exception: error) { "failed to remove access from #{users}" }
    self[:staff_access_error] = {
      message: "failed to remove access from #{users}",
      error:   error.message,
      at:      Time.utc.to_s,
    }
  end

  protected def grant_access_to(security, access_required)
    # update the setting first as we want to ensure access is removed
    @host_access_mutex.synchronize do
      access_required.each do |(needs_access, email, cardholder_id)|
        if needs_access
          access_granted[email] = cardholder_id
        else
          existing_access[email] = cardholder_id
        end
      end

      # we define the setting here as remove access would have run first
      define_setting(:access_granted, access_granted)
    end

    # grant users access to zones
    access_required.each do |(needs_access, email, cardholder_id)|
      next unless needs_access
      security.zone_access_add_member(access_group_id, cardholder_id).get rescue nil
    end
  rescue error
    logger.error(exception: error) { "failed to grant access to #{access_required.map(&.[](1))}" }
    self[:staff_access_error] = {
      message: "failed to grant access to #{access_required.map(&.[](1))}",
      error:   error.message,
      at:      Time.utc.to_s,
    }
  end

  # =============================================================
  # Meeting-driven extra security group access
  # (config.control_system.security_groups)
  # =============================================================

  # gallagher group id => { email => cardholder_id } — only users WE granted
  # are tracked. Anyone who already had access to a group is left alone.
  getter meeting_security_access : Hash(String, Hash(String, String | Int64)) = {} of String => Hash(String, String | Int64)
  @meeting_security_mutex = Mutex.new
  @cached_zone_lookups : Hash(String, String | Int64) = {} of String => String | Int64
  @cached_cardholder_lookups : Hash(String, String | Int64) = {} of String => String | Int64

  # Reconcile membership of `config.control_system.security_groups` for the
  # current meeting host(s):
  #   - pending/busy → host_email (and next_host) should be members
  #   - free / no status → no one should be a member (anyone we granted is removed)
  # Uses the diff/apply pattern so users that already had access (added by
  # someone else) are never modified.
  def reconcile_meeting_security_group_access : Nil
    groups = (config.control_system.try(&.security_groups) || [] of String).reject(&.empty?)

    desired_users = if groups.empty?
                      [] of String
                    else
                      desired_users_for_status(bookings.status?(Status, :status))
                    end

    security = gallagher

    # build group_id => { email => cardholder_id } from the desired set
    desired = {} of String => Hash(String, String | Int64)
    groups.each do |name_or_id|
      zone_id = lookup_security_zone_id(security, name_or_id)
      next unless zone_id
      group_key = zone_id.to_s

      desired_users.each do |email|
        cardholder_id = lookup_security_cardholder_id(security, email)
        next unless cardholder_id

        bucket = desired[group_key] ||= {} of String => String | Int64
        bucket[email] = cardholder_id
      end
    end

    apply_meeting_security_diff(security, desired)
  rescue error
    logger.error(exception: error) { "failed to reconcile meeting security group access" }
    self[:meeting_security_error] = {
      message: error.message,
      at:      Time.utc.to_s,
    }
  end

  protected def desired_users_for_status(status : Status?) : Array(String)
    return [] of String if status.nil?
    case status
    in .pending?, .busy?
      hosts = [
        bookings.status?(String, :host_email).try(&.strip.downcase),
        bookings.status?(String, :next_host).try(&.strip.downcase),
      ].compact
      hosts.reject(&.empty?).uniq!
    in .free?
      [] of String
    end
  end

  protected def apply_meeting_security_diff(
    security,
    desired : Hash(String, Hash(String, String | Int64)),
  ) : Nil
    all_groups = (@meeting_security_access.keys + desired.keys).uniq
    new_state = {} of String => Hash(String, String | Int64)

    all_groups.each do |group_id|
      new_users = desired[group_id]? || {} of String => String | Int64
      old_users = @meeting_security_access[group_id]? || {} of String => String | Int64

      tracked = {} of String => String | Int64

      # remove users we previously granted but no longer need
      (old_users.keys - new_users.keys).each do |email|
        cardholder_id = old_users[email]
        begin
          security.zone_access_remove_member(group_id, cardholder_id).get
          logger.debug { "removed #{email} from gallagher group #{group_id}" }
        rescue error
          logger.warn(exception: error) { "failed removing #{email} from gallagher group #{group_id}" }
        end
      end

      # users in both — already granted by us, keep tracking, no API call
      (new_users.keys & old_users.keys).each do |email|
        tracked[email] = new_users[email]
      end

      # newly required users — grant access, but skip those who were already
      # members (someone else granted them — we don't take responsibility)
      (new_users.keys - old_users.keys).each do |email|
        cardholder_id = new_users[email]
        begin
          already_member = (security.zone_access_member?(group_id, cardholder_id).get.raw rescue nil)
          if already_member
            logger.debug { "#{email} already a member of gallagher group #{group_id}, leaving untouched" }
            next
          end

          security.zone_access_add_member(group_id, cardholder_id).get
          tracked[email] = cardholder_id
          logger.debug { "granted #{email} access to gallagher group #{group_id}" }
        rescue error
          logger.warn(exception: error) { "failed adding #{email} to gallagher group #{group_id}" }
        end
      end

      new_state[group_id] = tracked unless tracked.empty?
    end

    @meeting_security_mutex.synchronize do
      @meeting_security_access = new_state
      begin
        define_setting(:meeting_security_access, @meeting_security_access)
      rescue error
        logger.warn(exception: error) { "failed to persist meeting_security_access setting" }
      end
    end
  end

  protected def lookup_security_zone_id(security, name_or_id : String) : String | Int64 | Nil
    if id = @cached_zone_lookups[name_or_id]?
      return id
    end

    # treat the value as a name first
    id_raw = security.zone_access_id_lookup(name_or_id).get
    if id = id_raw.as_s? || id_raw.as_i64?
      @cached_zone_lookups[name_or_id] = id
      return id
    end

    # fall back to checking it was already an id
    if (security.zone_access_lookup(name_or_id).get rescue nil)
      @cached_zone_lookups[name_or_id] = name_or_id
      return name_or_id
    end

    logger.warn { "gallagher zone lookup failed for: #{name_or_id}" }
    nil
  rescue error
    logger.warn(exception: error) { "gallagher zone lookup error for: #{name_or_id}" }
    nil
  end

  protected def lookup_security_cardholder_id(security, email : String) : String | Int64 | Nil
    email = email.strip.downcase
    return nil if email.empty?
    if id = @cached_cardholder_lookups[email]?
      return id
    end

    json = (security.card_holder_id_lookup(email).get rescue nil)
    return nil unless json && json.raw

    id = (String | Int64).from_json(json.to_json)
    @cached_cardholder_lookups[email] = id
    id
  rescue error
    logger.warn(exception: error) { "gallagher cardholder lookup error for: #{email}" }
    nil
  end
end
