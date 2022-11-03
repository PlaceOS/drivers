require "./cres_next"
require "placeos-driver/interface/sensor"

class Crestron::OccupancySensor < Crestron::CresNext # < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "Crestron Occupancy Sensor"
  generic_name :Occupancy

  uri_base "wss://192.168.0.5/websockify"

  default_settings({
    username: "admin",
    password: "admin",
  })

  @mac : String = ""
  @name : String? = nil
  @occupied : Bool = false
  @connected : Bool = false
  getter last_update : Int64 = 0_i64

  def connected
    @connected = true

    query("/OccupancySensor/IsRoomOccupied") do |occupied|
      @last_update = Time.utc.to_unix
      self[:occupied] = @occupied = occupied.as_bool
    end

    query("/DeviceInfo/MacAddress") do |mac|
      self[:mac] = @mac = format_mac mac.as_s
    end

    query("/DeviceInfo/Name") do |name|
      self[:name] = @name = name.as_s?
    end
  end

  def disconnected
    @connected = false
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }

    return unless raw_json.includes? "IsRoomOccupied"
    payload = JSON.parse(raw_json)

    @last_update = Time.utc.to_unix
    self[:occupied] = @occupied = payload.dig("Device", "OccupancySensor", "IsRoomOccupied").as_bool

    task.try &.success
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
