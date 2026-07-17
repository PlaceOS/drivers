require "placeos-driver"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/device_info"
require "placeos-driver/interface/presence_smoother"
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

    # occupancy smoothing: raw sensor readings are observed continuously and
    # the exposed presence is only flipped once one state dominates the sliding
    # window, avoiding flicker from an unreliable PIR / ultrasonic sensor
    presence_smoothing_window_sec: 120,
    presence_smoothing_threshold:  0.7,
    presence_evaluation_sec:       10,
  })

  @mac : String = ""
  @name : String? = nil
  @occupied : Bool? = nil
  getter last_update : Int64 = 0_i64
  getter poll_counter : UInt64 = 0_u64

  @sensor_data : Array(Interface::Sensor::Detail) = Array(Interface::Sensor::Detail).new(1)
  @monitoring : Bool = false
  @lock : Mutex = Mutex.new

  # smooths the noisy sensor and serialises access to it (observe vs poll) so a
  # poll's timestamp can never precede a concurrent observation
  @presence_lock : Mutex = Mutex.new
  @presence_window : Time::Span = 3.minutes
  @presence_threshold : Float64 = 0.7
  @presence_evaluation : Time::Span = 10.seconds
  @smoother : PlaceOS::Driver::Presence::Smoother = PlaceOS::Driver::Presence::Smoother.new

  def on_load
  end

  @authenticating : Bool = false

  def on_update
    @authenticating = false

    window = (setting?(Int32, :presence_smoothing_window_sec) || 120).seconds
    threshold = setting?(Float64, :presence_smoothing_threshold) || 0.7
    @presence_evaluation = (setting?(Int32, :presence_evaluation_sec) || 10).seconds

    # only rebuild the smoother (losing its history) when the tuning changes
    if window != @presence_window || threshold != @presence_threshold
      @presence_window = window
      @presence_threshold = threshold
      @presence_lock.synchronize { @smoother = PlaceOS::Driver::Presence::Smoother.new(window, threshold) }
    end

    connected
  end

  def connected
    schedule.clear
    schedule.every(10.minutes) { authenticate }
    schedule.every(@presence_evaluation) { update_sensor }
    schedule.in(1.second) { authenticate } unless @authenticating
    @authenticating = true
  end

  # records a raw sensor reading against the smoother
  protected def observe_presence(occupied : Bool) : Nil
    @presence_lock.synchronize { @smoother.observe(occupied) }
  end

  protected def on_authenticated : Nil
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
    observe_presence(payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool)
    mac = payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    self[:mac] = @mac = format_mac(mac)
    self[:name] = @name = payload.dig?("Device", "DeviceInfo", "Name").try(&.as_s?).presence

    # reflect the initial reading immediately (the schedule takes over from here)
    update_sensor

    # Start long polling once we have state.
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
      # a keep-alive / unrelated update - just note the device is still alive.
      # The scheduled update_sensor refreshes last_seen from here.
      @last_update = Time.utc.to_unix if payload["Device"]?.try(&.raw)
      return true
    end

    # record the raw reading; the scheduled update_sensor evaluates the
    # smoothed state and publishes it
    @last_update = Time.utc.to_unix
    observe_presence(payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool)

    true
  rescue timeout : IO::TimeoutError
    logger.debug { "timeout waiting for long poll to complete" }
    false
  rescue error
    logger.warn(exception: error) { "during long polling" }
    false
  end

  @update_lock = Mutex.new

  # Evaluates the smoothed occupancy and publishes it. Called on a schedule
  # (independently of the sensor's long poll, which only records observations)
  # and once directly after the initial device query for a prompt first value.
  def update_sensor : Nil
    snapshot = @presence_lock.synchronize { @smoother.poll }

    # no raw observations recorded yet - nothing to publish
    return if snapshot.nil?

    occupied = snapshot.state
    self[:occupied] = @occupied = occupied
    self[:presence] = occupied ? 1.0 : 0.0
    self[:raw_occupied] = snapshot.raw_state
    self[:presence_confidence] = snapshot.confidence_percent

    value = occupied ? 1.0 : 0.0
    last_seen = authenticated? ? Time.utc.to_unix : @last_update
    status = authenticated? ? Status::Normal : Status::Fault

    @update_lock.synchronize do
      if sensor = @sensor_data[0]?
        sensor.value = value
        sensor.last_seen = last_seen
        sensor.mac = @mac
        sensor.name = @name
        sensor.status = status
      else
        @sensor_data << Detail.new(
          type: :presence,
          value: value,
          last_seen: last_seen,
          mac: @mac,
          id: nil,
          name: @name,
          module_id: module_id,
          binding: "presence",
          status: status,
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
