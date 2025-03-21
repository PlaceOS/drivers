require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./cres_next_auth"
require "perf_tools/mem_prof"

# This device doesn't seem to support a websocket interface
# and relies on long polling.

class Crestron::OccupancySensor < PlaceOS::Driver
  include Crestron::CresNextAuth
  include Interface::Sensor

  descriptive_name "Crestron Occupancy Sensor"
  generic_name :Occupancy

  uri_base "https://192.168.0.5"

  default_settings({
    username: "admin",
    password: "admin",
  })

  @mac : String = ""
  @name : String? = nil
  @occupied : Bool = false
  @connected : Bool = false
  getter last_update : Int64 = 0_i64
  getter poll_counter : UInt64 = 0_u64

  @sensor_data : Array(Interface::Sensor::Detail) = Array(Interface::Sensor::Detail).new(1)

  def on_load
    spawn { event_monitor }
    schedule.every(10.minutes) { authenticate }
    schedule.every(1.hour) { poll_device_state }
  end

  def connected
    @connected = true

    authenticate
    poll_device_state
  end

  def disconnected
    @connected = false
  end

  def poll_device_state : Nil
    response = get("/Device")
    raise "unexpected response code: #{response.status_code}" unless response.success?
    payload = JSON.parse(response.body)

    @last_update = Time.utc.to_unix
    self[:occupied] = @occupied = payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool
    self[:presence] = @occupied ? 1.0 : 0.0
    self[:mac] = @mac = format_mac payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    self[:name] = @name = payload.dig("Device", "DeviceInfo", "Name").as_s?

    update_sensor

    # Start long polling once we have state
    @poll_counter += 1
  end

  protected def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def event_monitor
    loop do
      break if terminated?
      if @connected
        # sleep if long poll failed
        sleep 1.second unless long_poll
      else
        # sleep if not connected
        sleep 1.second
      end
    end
  end

  # remove once resolved
  def memory_object_counts : String
    String.build do |io|
      PerfTools::MemProf.log_object_counts(io)
    end
  end

  def memory_object_sizes : String
    String.build do |io|
      PerfTools::MemProf.log_object_sizes(io)
    end
  end

  def memory_allocations : String
    String.build do |io|
      PerfTools::MemProf.log_allocations(io)
    end
  end

  # NOTE:: /Device/Longpoll
  # 200 == check data
  #  when nothing new: {"Device":"Response Timeout"}
  #  when update: {"Device":{"SystemClock":{"CurrentTime":"2022-10-22T20:29:03Z","CurrentTimeWithOffset":"2022-10-22T20:29:03+09:30"}}}
  # 301 == authentication required
  #  could auth every so often to prevent hitting this too
  protected def long_poll : Bool
    response = get("/Device/Longpoll", concurrent: true)

    # retry after authenticating
    if response.status_code == 301
      authenticate
      response = get("/Device/Longpoll", concurrent: true)
    end
    raise "unexpected response code: #{response.status_code}" unless response.success?

    raw_json = response.body
    logger.debug { "long poll sent: #{raw_json}" }

    return true unless raw_json.includes? "IsRoomOccupied"
    payload = JSON.parse(raw_json)

    @last_update = Time.utc.to_unix
    self[:occupied] = @occupied = payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool
    self[:presence] = @occupied ? 1.0 : 0.0
    update_sensor

    true
  rescue timeout : IO::TimeoutError
    logger.debug { "timeout waiting for long poll to complete" }
    false
  rescue error
    logger.warn(exception: error) { "during long polling" }
    false
  end

  @update_lock = Mutex.new

  protected def update_sensor
    @update_lock.synchronize do
      if sensor = @sensor_data[0]?
        sensor.value = @occupied ? 1.0 : 0.0
        sensor.last_seen = @connected ? Time.utc.to_unix : @last_update
        sensor.mac = @mac
        sensor.name = @name
        sensor.status = @connected ? Status::Normal : Status::Fault
      else
        @sensor_data << Detail.new(
          type: :presence,
          value: @occupied ? 1.0 : 0.0,
          last_seen: @connected ? Time.utc.to_unix : @last_update,
          mac: @mac,
          id: nil,
          name: @name,
          module_id: module_id,
          binding: "presence",
          status: @connected ? Status::Normal : Status::Fault,
        )
      end
    end
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if mac && mac != @mac
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    @sensor_data
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless @mac == mac
    @sensor_data[0]?
  end

  def get_sensor_details
    @sensor_data[0]?
  end
end
