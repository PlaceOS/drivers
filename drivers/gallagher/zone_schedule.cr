require "placeos-driver"
require "simple_retry"

class Gallagher::ZoneSchedule < PlaceOS::Driver
  descriptive_name "Gallagher Zone Schedule"
  generic_name :GallagherZoneSchedule
  description "maps a booking state to a gallagher access zone state"

  default_settings({
    # gallagher_system: "sys-12345"
    zone_id: "1234",

    # booking status => zone state
    state_mappings: {
      "pending" => "free",
      "busy"    => "free",
      "free"    => "default",
    },

    # max time in minutes that presence can prevent a lock
    presence_timeout: 30,
  })

  getter system_id : String = ""
  getter count : UInt64 = 0_u64

  # Tracking meeting details
  getter zone_id : String | Int64 = ""
  getter state_mappings : Hash(String, String) = {} of String => String

  @update_mutex = Mutex.new

  def on_update
    @system_id = setting?(String, :gallagher_system).presence || config.control_system.not_nil!.id
    @state_mappings = setting(Hash(String, String), :state_mappings)
    @zone_id = setting?(String | Int64, :zone_id) || setting(String | Int64, :door_zone_id)
    @presence_timeout = (setting?(Int32, :presence_timeout) || 30).minutes
  end

  bind Bookings_1, :status, :status_changed
  bind Bookings_1, :presence, :presence_changed

  getter last_status : String? = nil
  getter last_presence : Bool? = nil

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

    # ignore redis errors as this is a critical system component
    begin
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
  end

  private def gallagher
    system(system_id)["Gallagher"]
  end
end
