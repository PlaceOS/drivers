require "placeos-driver"

# Hooks into room occupancy status to decide if the air should be flowing into the space.
# Simply add this module to multiple rooms and if they have a VAV in common then both
# Rooms data will be taken into account when deciding to turn on or off the air.
# BACnet system and module can be in a remote system so you don't have to add to each system.
#
# To find a device ID, you can execute BACnet_1.devices => known device list
# then you can search for the device name
class Ashrae::BACnetVAVControl < PlaceOS::Driver
  generic_name :VAVControl
  descriptive_name "Variable Air Volume Control"
  description %(Opens and closes VAV box relays to control how much air enters the room)

  struct VavId
    include JSON::Serializable

    getter object : Int32
    getter instance : Int32 = 1

    getter lookup_id : String { "#{object}_#{instance}" }
  end

  default_settings({
    _bacnet_system_id: "sys-1234",
    _bacnet_module:    "BACnet_1",

    instance_type: "multi_state_value",
    vav_ids:       [{
      object:   1234,
      instance: 1,
    }],
    vav_write_priority: 14,

    vav_off_delay_sec:    5 * 60,
    vav_sensor_delay_sec: 2 * 60,
    vav_disable_sensor:   false,

    # enum values
    # Occupied = 1
    # Off = 2
    # unoccupied = 3
    # Standby = 4
    # fire = 5
    vav_off_state: 3,
    vav_on_state:  1,
  })

  @vav_ids : Array(VavId) = [] of VavId
  @instance_type : String = "multi_state_value"
  @bacnet_module : String = "BACnet_1"
  getter system_id : String { config.control_system.not_nil!.id }
  getter bacnet_system_id : String { system_id }

  # state variables
  getter? room_booked : Bool = false
  getter? sensor_active : Bool = true
  getter? presence : Bool = false

  @vav_disable_sensor : Bool = false
  @vav_sensor_delay_sec : Time::Span = 2.minutes
  @vav_off_delay_sec : Time::Span = 5.minutes
  @vav_write_priority : Int32 = 14
  @vav_off_state : Int32 = 3
  @vav_on_state : Int32 = 1

  bind Bookings_1, :status, :booking_status_changed
  bind Bookings_1, :sensor_stale, :booking_stale_changed
  bind Bookings_1, :presence, :booking_presence_changed

  def on_load
    on_update rescue nil
    schedule.every(3.minutes) { update_ttl }
  end

  def on_update
    @vav_ids = setting(Array(VavId), :vav_ids)
    @instance_type = setting?(String, :instance_type) || "multi_state_value"
    @bacnet_system_id = setting?(String, :bacnet_system_id)
    @bacnet_module = setting?(String, :bacnet_module) || "BACnet_1"

    @vav_disable_sensor = setting?(Bool, :vav_disable_sensor) || false
    @vav_sensor_delay_sec = (setting?(Int32, :vav_sensor_delay_sec) || (2 * 60)).seconds
    @vav_off_delay_sec = (setting?(Int32, :vav_off_delay_sec) || (5 * 60)).seconds
    @vav_write_priority = setting?(Int32, :vav_write_priority) || 14
    @vav_off_state = setting?(Int32, :vav_off_state) || 3
    @vav_on_state = setting?(Int32, :vav_on_state) || 1
  end

  protected def booking_status_changed(_subscription, value : String)
    logger.info { "booking status changed to: #{value}" }
    status = String?.from_json(value)
    case status
    when Nil
      return
    when "free"
      @room_booked = false
    else
      @room_booked = true
    end

    update_state
  end

  # we also care if there is someone in the space and that the sensor is working
  protected def booking_stale_changed(_subscription, value : String)
    logger.info { "stale sensor changed to: #{value}" }
    @sensor_active = value != "true"
    update_state
  end

  protected def booking_presence_changed(_subscription, value : String)
    logger.info { "sensor presence changed to: #{value}" }
    @presence = value == "true"
    update_state
  end

  @update_mutex : Mutex = Mutex.new(:reentrant)
  @off_timer : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
  # debounces sensor-driven turn on so a brief false positive doesn't flip the air on
  @on_timer : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  # this is our understanding of the current state (ignoring the off delay)
  getter? vav_active : Bool = false

  protected def apply_vav_state(vav_on : Bool)
    @update_mutex.synchronize do
      @vav_active = vav_on
      agreement = true
      store_value = vav_on.to_s

      @vav_ids.each do |vav|
        storage = PlaceOS::Driver::RedisStorage.new(vav.lookup_id, @instance_type)
        storage.set_expire(system_id, store_value, ttl: 7.minutes)

        # ensure all systems have no people in them
        if !vav_on && agreement
          agreement = !storage.values.includes?("true")
        end
      end

      if vav_on
        turn_on_vav
      elsif agreement
        turn_off_vav
      else
        cancel_on_timer

        # vav is off but there is not cross room agreement
        logger.info { "No presence in room, however no agreement reached on vav state across spaces. No change applied." }
        if @off_timer.nil?
          @off_timer = schedule.in(TTL_TIME) { check_before_turning_off }
        end
      end
    end
  end

  protected def update_state
    return apply_vav_state(true) if room_booked?

    if @vav_disable_sensor
      room_in_use = false
    else
      # we default to true if the sensor has failed
      room_in_use = sensor_active? ? presence? : true
    end

    @update_mutex.synchronize do
      # check if the sensor has detected something, otherwise the room is off
      if room_in_use
        return apply_vav_state(true) if @vav_sensor_delay_sec.zero?

        if @on_timer.nil?
          cancel_off_timer
          @on_timer = schedule.in(@vav_sensor_delay_sec) { apply_vav_state(true) }
          self[:vav_pending_on] = true
        end

        return
      end

      # otherwise the room has no occupancy and is not in use.
      return if @off_timer
      cancel_on_timer
      @off_timer = schedule.in(@vav_off_delay_sec) { apply_vav_state(false) }
      self[:vav_pending_off] = true
    end
  end

  # cancels a pending sensor-driven turn on (must be called holding @update_mutex)
  protected def cancel_on_timer : Nil
    if on_timer = @on_timer
      on_timer.cancel rescue nil
      @on_timer = nil
    end
    self[:vav_pending_on] = false
  end

  # cancels a pending sensor-driven turn on (must be called holding @update_mutex)
  protected def cancel_off_timer : Nil
    if off_timer = @off_timer
      off_timer.cancel rescue nil
      @off_timer = nil
    end
    self[:vav_pending_off] = false
  end

  TTL_TIME = 7.minutes

  protected def update_ttl
    @update_mutex.synchronize do
      @vav_ids.each do |vav|
        storage = PlaceOS::Driver::RedisStorage.new(vav.lookup_id, @instance_type)
        storage.expire(system_id, ttl: TTL_TIME)
      end
    end
  end

  # if multiple rooms share a VAV this ensures we leave it on if there is activity elsewhere
  protected def check_before_turning_off : Nil
    return if vav_active?
    agreement = true

    @update_mutex.synchronize do
      @off_timer.try(&.cancel) rescue nil
      @off_timer = nil

      # ensure all systems have no people in them
      @vav_ids.each do |vav|
        storage = PlaceOS::Driver::RedisStorage.new(vav.lookup_id, @instance_type)
        agreement = !storage.values.includes?("true")
        break unless agreement
      end
    end

    return turn_off_vav if agreement

    @update_mutex.synchronize do
      if @off_timer.nil?
        @off_timer = schedule.in(TTL_TIME) { check_before_turning_off } unless vav_active?
      end
    end
  end

  # by default this will select the spec system id. So specs will still work
  protected def bacnet
    system(bacnet_system_id).get(@bacnet_module)
  end

  def turn_off_vav
    # turning off supersedes any pending turn on
    cancel_off_timer
    cancel_on_timer
    @vav_ids.each do |vav|
      bacnet.write_unsigned_int(vav.object, vav.instance, @vav_off_state, @instance_type, @vav_write_priority).get_json rescue nil
    end
    self[:vav_active] = false
    logger.info { "turned vav off" }
  end

  def turn_on_vav
    # turning on supersedes any pending turn off - otherwise a stale off timer
    # (armed while the room was empty) could later switch the air off mid-use
    cancel_on_timer
    cancel_off_timer
    @vav_ids.each do |vav|
      bacnet.write_unsigned_int(vav.object, vav.instance, @vav_on_state, @instance_type, @vav_write_priority).get_json rescue nil
    end
    self[:vav_active] = true
    logger.info { "turned vav on" }
  end
end
