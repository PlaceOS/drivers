require "placeos-driver"

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

    vav_off_delay_sec: 5 * 60,

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
  getter? sensor_active : Bool = false
  getter? presence : Bool = false

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

    @vav_off_delay_sec = (setting?(Int32, :vav_off_delay_sec) || (5 * 60)).seconds
    @vav_write_priority = setting?(Int32, :vav_write_priority) || 14
    @vav_off_state = setting?(Int32, :vav_off_state) || 3
    @vav_on_state = setting?(Int32, :vav_on_state) || 1
  end

  protected def booking_status_changed(_subscription, value : String)
    status = String.from_json(value)
    case status
    when "free"
      @room_booked = false
    else
      @room_booked = true
    end

    update_state
  end

  # we also care if there is someone in the space and that the sensor is working
  protected def booking_stale_changed(_subscription, value : String)
    @sensor_active = value != "true"
    update_state
  end

  protected def booking_presence_changed(_subscription, value : String)
    @presence = value == "true"
    update_state
  end

  @update_mutex : Mutex = Mutex.new
  @off_timer : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  # this is our understanding of the current state (ignoring the off delay)
  getter? vav_active : Bool = false

  protected def update_state
    # we default to true if the sensor has failed
    room_in_use = sensor_active? ? presence? : true
    activate_vav = room_booked? || room_in_use
    store_value = activate_vav.to_s

    @update_mutex.synchronize do
      agreement = true

      @vav_ids.each do |vav|
        storage = PlaceOS::Driver::RedisStorage.new(vav.lookup_id, @instance_type)
        storage.set_expire(system_id, store_value, ttl: 7.minutes)

        # ensure all systems have no people in them
        if !activate_vav && agreement
          agreement = !storage.values.includes?("true")
        end
      end

      if activate_vav
        # send turn on signal
        if off_timer = @off_timer
          off_timer.cancel rescue nil
          @off_timer = nil
        end
        @vav_active = true
        turn_on_vav
      elsif agreement
        @vav_active = false

        # schedule turn off
        return if @off_timer
        @off_timer = schedule.in(@vav_off_delay_sec) { check_before_turning_off }
      end
    end
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
    agreement = true
    return if @vav_active

    @update_mutex.synchronize do
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
      @off_timer = schedule.in(TTL_TIME) { check_before_turning_off } unless @vav_active
    end
  end

  # by default this will select the spec system id. So specs will still work
  protected def bacnet
    system(bacnet_system_id).get(@bacnet_module)
  end

  def turn_off_vav
    @vav_ids.each do |vav|
      bacnet.write_unsigned_int(vav.object, vav.instance, @vav_off_state, @instance_type, @vav_write_priority).get_json rescue nil
    end
    self[:vav_pending_off] = false
    self[:vav_active] = false
  end

  def turn_on_vav
    @vav_ids.each do |vav|
      bacnet.write_unsigned_int(vav.object, vav.instance, @vav_on_state, @instance_type, @vav_write_priority).get_json rescue nil
    end
    self[:vav_pending_off] = false
    self[:vav_active] = true
  end
end
