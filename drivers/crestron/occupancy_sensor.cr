require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./cres_next_auth"

# This device doesn't seem to support a websocket interface
# and relies on long polling

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

  @long_polling = false

  def on_load
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
    self[:mac] = @mac = format_mac payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    self[:name] = @name = payload.dig("Device", "DeviceInfo", "Name").as_s?

    # Start long polling once we have state
    @poll_counter += 1
    long_poll unless @long_polling
  end

  protected def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  # NOTE:: /Device/Longpoll
  # 200 == check data
  #  when nothing new: {"Device":"Response Timeout"}
  #  when update: {"Device":{"SystemClock":{"CurrentTime":"2022-10-22T20:29:03Z","CurrentTimeWithOffset":"2022-10-22T20:29:03+09:30"}}}
  # 301 == authentication required
  #  could auth every so often to prevent hitting this too
  protected def long_poll
    @long_polling = true
    response = get("/Device/Longpoll")

    authenticate if response.status_code == 301
    raise "unexpected response code: #{response.status_code}" unless response.success?

    raw_json = response.body
    logger.debug { "long poll sent: #{raw_json}" }

    return unless raw_json.includes? "IsRoomOccupied"
    payload = JSON.parse(raw_json)

    @last_update = Time.utc.to_unix
    self[:occupied] = @occupied = payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool
  rescue timeout : IO::TimeoutError
    logger.debug { "timeout waiting for long poll to complete" }
  rescue error
    logger.warn(exception: error) { "during long polling" }
  ensure
    if @connected
      spawn(same_thread: true) { long_poll }
    else
      @long_polling = false
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

    [get_sensor_details]
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless @mac == mac
    get_sensor_details
  end

  def get_sensor_details
    Detail.new(
      type: :presence,
      value: @occupied ? 1.0 : 0.0,
      last_seen: @connected ? Time.utc.to_unix : @last_update,
      mac: @mac,
      id: nil,
      name: @name,
      module_id: module_id,
      binding: "occupied",
      status: @connected ? Status::Normal : Status::Fault,
    )
  end
end
