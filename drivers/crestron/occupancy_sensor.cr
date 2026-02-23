require "placeos-driver"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/device_info"
require "./cres_next_auth"

# This device doesn't seem to support a websocket interface
# and relies on long polling.

class Crestron::OccupancySensor < PlaceOS::Driver
  include Crestron::CresNextAuth
  include Interface::Sensor
  include Interface::DeviceInfo

  descriptive_name "Crestron Occupancy Sensor"
  generic_name :Occupancy

  uri_base "https://192.168.0.5"

  default_settings({
    username: "admin",
    password: "admin",

    http_keep_alive_seconds: 600,
    http_max_requests:       1200,
  })

  @mac : String = ""
  @name : String? = nil
  @occupied : Bool? = nil
  getter last_update : Int64 = 0_i64
  getter poll_counter : UInt64 = 0_u64

  @sensor_data : Array(Interface::Sensor::Detail) = Array(Interface::Sensor::Detail).new(1)
  @monitoring : Bool = false
  @lock : Mutex = Mutex.new

  def on_load
    # re-authenticate every 10 minutes
    schedule.every(10.minutes) { authenticate }

    # sync device state every hour
    # this is handled by Interface::DeviceInfo
    # schedule.every(1.hour) { poll_device_state }
  end

  def on_update
    authenticate
  end

  def connected
    if !authenticated?
      # connected is called again by the authenticate function.
      spawn { authenticate }
      return
    end

    @lock.synchronize do
      if !@monitoring
        spawn { event_monitor }
        @monitoring = true
      end
    end
  end

  def poll_device_state : Nil
    device_info
  end

  def device_info : Descriptor
    response = get("/Device", concurrent: true)
    raise "unexpected response code: #{response.status_code}" unless response.success?
    payload = JSON.parse(response.body)

    logger.debug { "device details payload: #{payload.to_pretty_json}" }

    @last_update = Time.utc.to_unix
    self[:occupied] = @occupied = payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool
    self[:presence] = @occupied ? 1.0 : 0.0
    mac = payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    self[:mac] = @mac = format_mac(mac)
    self[:name] = @name = payload.dig?("Device", "DeviceInfo", "Name").try(&.as_s?).presence

    update_sensor

    # Start long polling once we have state
    @poll_counter += 1

    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceInfo.htm
    ip_address = config.ip.presence || URI.parse(config.uri.as(String)).hostname
    model = payload.dig("Device", "DeviceInfo", "Model").as_s
    model_type = payload.dig?("Device", "DeviceInfo", "ModelSubType").try(&.as_s?)
    model_type = " (#{model_type})" if model_type.presence
    category = payload.dig("Device", "DeviceInfo", "Category").as_s

    fw_version = payload.dig("Device", "DeviceInfo", "Version").as_s
    hw_version = payload.dig("Device", "DeviceInfo", "DeviceVersion").as_s
    puf_version = payload.dig("Device", "DeviceInfo", "PufVersion").as_s
    build_date = payload.dig("Device", "DeviceInfo", "BuildDate").as_s

    Descriptor.new(
      make: "Crestron",
      model: "#{category} #{model}#{model_type}",
      serial: payload.dig("Device", "DeviceInfo", "SerialNumber").as_s,
      firmware: "#{fw_version}, device #{hw_version}, puf #{puf_version}, built #{build_date}",
      mac_address: mac,
      ip_address: ip_address,
      hostname: @name,
    )
  end

  protected def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def event_monitor
    loop do
      break if terminated?
      if authenticated?
        # sleep if long poll failed
        logger.debug { "event monitor: performing long poll" }
        sleep 1.second unless long_poll
      else
        # sleep if not authenticated
        logger.debug { "event monitor: idling as not authenticated" }
        sleep 1.second
      end
    end
  end

  # NOTE:: /Device/Longpoll
  # 200 == check data
  #  when nothing new: {"Device":"Response Timeout"}
  #  when update: {"Device":{"SystemClock":{"CurrentTime":"2022-10-22T20:29:03Z","CurrentTimeWithOffset":"2022-10-22T20:29:03+09:30"}}}
  # 301 == authentication required
  #  could auth every so often to prevent hitting this too
  protected def long_poll : Bool
    response = get("/Device/Longpoll")

    # retry after authenticating
    if response.status_code == 301
      authenticate
      response = get("/Device/Longpoll")
    end
    raise "unexpected response code: #{response.status_code}" unless response.success?

    raw_json = response.body
    logger.debug { "long poll sent: #{raw_json}" }
    payload = JSON.parse(raw_json)

    if !raw_json.includes?("IsRoomOccupied")
      if !@occupied.nil? && payload["Device"]?.try(&.raw)
        @last_update = Time.utc.to_unix
        update_sensor
      end
      return true
    end

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
        sensor.last_seen = authenticated? ? Time.utc.to_unix : @last_update
        sensor.mac = @mac
        sensor.name = @name
        sensor.status = authenticated? ? Status::Normal : Status::Fault
      else
        @sensor_data << Detail.new(
          type: :presence,
          value: @occupied ? 1.0 : 0.0,
          last_seen: authenticated? ? Time.utc.to_unix : @last_update,
          mac: @mac,
          id: nil,
          name: @name,
          module_id: module_id,
          binding: "presence",
          status: authenticated? ? Status::Normal : Status::Fault,
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

    return NO_MATCH if @occupied.nil?
    return NO_MATCH if mac && mac != @mac
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    @sensor_data
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless @mac == mac && !@occupied.nil?
    @sensor_data[0]?
  end

  def get_sensor_details
    @sensor_data[0]?
  end
end
