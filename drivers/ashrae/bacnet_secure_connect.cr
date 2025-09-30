require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./bacnet_models"

# docs: https://bacnet.org/wp-content/uploads/sites/4/2022/08/Add-135-2016bj.pdf
# https://www.ashrae.org/file%20library/technical%20resources/standards%20and%20guidelines/standards%20addenda/135_2016_bj_20191118.pdfc

class Ashrae::BACnetSecureConnect < PlaceOS::Driver
  include Interface::Sensor

  generic_name :BACnet
  descriptive_name "BACnet Secure Connect"
  description "BACnet over secure websockets."

  uri_base "wss://server.domain.or.ip/hub"

  default_settings({
    _https_verify:      "none",
    _https_private_key: "-----BEGIN PRIVATE KEY-----",
    _https_client_cert: "-----BEGIN CERTIFICATE-----",
    verbose_debug:      false,
  })

  def websocket_headers
    HTTP::Headers{
      # NOTE:: use dc.bsc.bacnet.org for direct node to node connections
      "Sec-WebSocket-Protocol" => "hub.bsc.bacnet.org",
      "Host"                   => URI.parse(config.uri.not_nil!).host.as(String),
    }
  end

  getter! uuid : UUID
  @vmac : Bytes = BACnet::Client::SecureConnect.generate_vmac

  def on_load
    # don't wait for responses, the client will do that
    queue.wait = false

    # generate a UUID and save it for future use if none exists already
    if uuid = setting?(String, :bacnet_sc_uuid)
      @uuid = UUID.new(uuid)
    else
      @uuid = uuid = UUID.v4
      define_setting(:bacnet_sc_uuid, uuid.to_s)
    end

    on_update
  rescue error
    self[:load_error] = error.inspect_with_backtrace
  end

  def on_update
    @verbose_debug = setting?(Bool, :verbose_debug) || false
  end

  @verbose_debug : Bool = false

  def connected
    # Hook up the client to the transport
    client = ::BACnet::Client::SecureConnect.new(
      retries: 0,
      timeout: 2.seconds,
      uuid: uuid,
      vmac: @vmac,
    )
    client.on_transmit do |message|
      logger.debug { "request sent: #{message.inspect}" }
      send message
    end

    # connection response handling
    client.on_control_info do |message|
      # Track the discovery of devices once the connection is established
      case message.data_link.request_type
      when .connect_accept?
        registry = BACnet::Client::DeviceRegistry.new(client, logger)
        registry.on_new_device { |device| new_device_found(device) }
        @device_registry = registry

        schedule.clear
        schedule.in(5.seconds) { query_known_devices }
        schedule.every(60.seconds) { bacnet_client.heartbeat! }

        poll_period = setting?(UInt32, :poll_period) || 3
        schedule.every(poll_period.minutes) do
          logger.debug { "--- Polling all known bacnet devices" }
          keys = @mutex.synchronize { @devices.keys }
          keys.each { |device_id| poll_device(device_id) }
        end

        perform_discovery
      end
    end

    @bacnet_client = client
    client.connect!
  end

  def disconnected
    @bacnet_client = nil
    @device_registry = nil
    schedule.clear
  end

  protected getter! bacnet_client : ::BACnet::Client::SecureConnect
  protected getter! device_registry : ::BACnet::Client::DeviceRegistry

  alias DeviceInfo = ::BACnet::Client::DeviceRegistry::DeviceInfo

  @packets_processed : UInt64 = 0_u64
  @seen_devices : Hash(UInt32, DeviceAddress) = {} of UInt32 => DeviceAddress
  @devices : Hash(UInt32, DeviceInfo) = {} of UInt32 => DeviceInfo
  @mutex : Mutex = Mutex.new(:reentrant)

  protected def get_device(device_id : UInt32)
    @mutex.synchronize { @devices[device_id]? }
  end

  # Performs a WhoIs discovery against the BACnet network
  def perform_discovery : Nil
    bacnet_client.who_is
  end

  # directly sends the message to the remote
  @[Security(Level::Support)]
  def send_raw_message(hex : String)
    send hex.hexbytes, wait: false
  end

  protected def object_value(obj)
    val = obj.value.try &.value
    case val
    in ::BACnet::Time, ::BACnet::Date
      val.value
    in ::BACnet::BitString, BinData
      nil
    in ::BACnet::PropertyIdentifier
      val.property_type
    in ::BACnet::ObjectIdentifier
      {val.object_type, val.instance_number}
    in Nil, Bool, UInt64, Int64, String
      val
    in Float32, Float64
      val.nan? ? nil : val
    end
  rescue
    nil
  end

  protected def device_details(device)
    {
      name:        device.name,
      model_name:  device.model_name,
      vendor_name: device.vendor_name,

      vmac:    device.link_address_friendly,
      network: device.network,
      address: device.address,
      id:      device.object_ptr.instance_number,

      objects: device.objects.map { |obj|
        {
          name: obj.name,
          type: obj.object_type,
          id:   obj.instance_id,

          unit:  obj.unit,
          value: object_value(obj),
          seen:  obj.changed,
        }
      },
    }
  end

  def device(device_id : UInt32)
    device_details get_device(device_id).not_nil!
  end

  def devices
    device_registry.devices.map { |device| device_details device }
  end

  def query_known_devices
    sent = [] of UInt32
    @seen_devices.each_value do |info|
      sent << info.id.not_nil!
      logger.debug { "inspecting #{info.address} - #{info.id}" }
      device_registry.inspect_device(info.identifier, info.net, info.addr, link_address: info.address)
    end
    devices = setting?(Array(DeviceAddress), :known_devices) || [] of DeviceAddress
    devices.each do |info|
      if id = info.id
        next if id.in? sent
        sent << id
        logger.debug { "inspecting #{info.address} - #{info.id}" }
        device_registry.inspect_device(info.identifier, info.net, info.addr, link_address: info.address)
      end
    end
    "inspected #{sent.size} devices"
  end

  def poll_device(device_id : UInt32)
    device = get_device(device_id)
    return false unless device

    client = bacnet_client
    objects = @mutex.synchronize { device.objects.dup }
    objects.each do |obj|
      next unless obj.object_type.in?(::BACnet::Client::DeviceRegistry::OBJECTS_WITH_VALUES)
      name = object_binding(device_id, obj)
      queue(name: name, priority: 0, timeout: 500.milliseconds) do |task|
        spawn_action(task) do
          obj.sync_value(client)
          self[name] = object_value(obj)
        end
      end
      Fiber.yield
    end
    true
  end

  protected def spawn_action(task, &block : -> Nil)
    spawn { task.success block.call }
    Fiber.yield
  end

  alias ObjectType = ::BACnet::ObjectIdentifier::ObjectType

  def update_value(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    obj = get_object_details(device_id, instance_id, object_type)
    name = object_binding(device_id, obj)

    queue(name: name, priority: 50) do |task|
      spawn_action(task) do
        obj.sync_value(bacnet_client)
        self[name] = object_value(obj)
      end
    end
  end

  protected def get_object_details(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    device = get_device(device_id).not_nil!
    device.objects.find { |obj| obj.object_ptr.object_type == object_type && obj.object_ptr.instance_number == instance_id }.not_nil!
  end

  def write_real(device_id : UInt32, instance_id : UInt32, value : Float32, object_type : ObjectType = ObjectType::AnalogValue)
    object = get_object_details(device_id, instance_id, object_type)

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  def write_double(device_id : UInt32, instance_id : UInt32, value : Float64, object_type : ObjectType = ObjectType::LargeAnalogValue)
    object = get_object_details(device_id, instance_id, object_type)

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  def write_unsigned_int(device_id : UInt32, instance_id : UInt32, value : UInt64, object_type : ObjectType = ObjectType::PositiveIntegerValue)
    object = get_object_details(device_id, instance_id, object_type)

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  def write_signed_int(device_id : UInt32, instance_id : UInt32, value : Int64, object_type : ObjectType = ObjectType::IntegerValue)
    object = get_object_details(device_id, instance_id, object_type)

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  def write_string(device_id : UInt32, instance_id : UInt32, value : String, object_type : ObjectType = ObjectType::CharacterStringValue)
    object = get_object_details(device_id, instance_id, object_type)

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  def write_binary(device_id : UInt32, instance_id : UInt32, value : Bool, object_type : ObjectType = ObjectType::BinaryValue)
    val = value ? 1 : 0
    object = get_object_details(device_id, instance_id, object_type)
    val = ::BACnet::Object.new.set_value(val)
    val.short_tag = 9_u8

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyType::PresentValue,
          val,
          network: object.network,
          address: object.address,
          link_address: object.link_address,
        )
      end
    end
    value
  end

  protected def new_device_found(device)
    logger.debug { "new device found: #{device.name}, #{device.model_name} (#{device.vendor_name}) with #{device.objects.size} objects" }
    logger.debug { device.inspect } if @verbose_debug

    @mutex.synchronize { @devices[device.object_ptr.instance_number] = device }

    device_id = device.object_ptr.instance_number
    device.objects.each { |obj| self[object_binding(device_id, obj)] = object_value(obj) }
  end

  protected def object_binding(device_id, obj)
    "#{device_id}.#{obj.object_type}[#{obj.instance_id}]"
  end

  def received(bytes, task)
    # will be a no-op, just here in case
    task.try &.success
    logger.debug { "websocket sent: 0x#{bytes.hexstring}" }

    message = IO::Memory.new(bytes).read_bytes(::BACnet::Message::Secure)
    logger.debug { "message: #{message.inspect}" }

    bacnet_client.received message
    @packets_processed += 1_u64

    case message.data_link.request_type
    when .bvcl_result?
      dlink = message.data_link
      if dlink.result.result_code > 0
        logger.error { "received error response: #{dlink.error_message}" }
        return
      end
    end

    app = message.application
    is_iam = false
    is_cov = case app
             when ::BACnet::ConfirmedRequest
               app.service.cov_notification?
             when ::BACnet::UnconfirmedRequest
               is_iam = app.service.i_am?
               app.service.cov_notification?
             else
               false
             end

    network = message.network

    if network && is_cov
      vmac = message.data_link.source_address.as(String)
      if network.source_specifier
        addr = network.source_address
        net = network.source.network
      end
      device = message.objects.find { |obj| obj.tag == 1 }.not_nil!.to_object_id.instance_number
      # prop = message.objects.find { |obj| obj.tag == 2 }
      @seen_devices[device] = DeviceAddress.new(vmac, device, net, addr)
    end

    if network && is_iam
      vmac = message.data_link.source_address.as(String)
      details = ::BACnet::Client::Message::IAm.parse(message)
      device = details[:object_id].instance_number
      @seen_devices[device] = DeviceAddress.new(vmac, device, details[:network], details[:address])
    end
  end

  # ======================
  # Sensor interface
  # ======================

  protected def to_sensor(device_id, device, object, filter_type = nil) : Interface::Sensor::Detail?
    sensor_type = case object.unit
                  when Nil
                    # required for case statement to work
                    if object.name.includes? "count"
                      SensorType::Counter
                    end
                  when .degrees_fahrenheit?, .degrees_celsius?, .degrees_kelvin?
                    SensorType::Temperature
                  when .percent_relative_humidity?
                    SensorType::Humidity
                  when .pounds_force_per_square_inch?
                    SensorType::Pressure
                    # when
                    #  SensorType::Presence
                  when .volts?, .millivolts?, .kilovolts?, .megavolts?
                    SensorType::Voltage
                  when .milliamperes?, .amperes?
                    SensorType::Current
                  when .millimeters_of_water?, .centimeters_of_water?, .inches_of_water?, .cubic_feet?, .cubic_meters?, .imperial_gallons?, .milliliters?, .liters?, .us_gallons?
                    SensorType::Volume
                  when .milliwatts?, .watts?, .kilowatts?, .megawatts?, .watt_hours?, .kilowatt_hours?, .megawatt_hours?
                    SensorType::Power
                  when .hertz?, .kilohertz?, .megahertz?
                    SensorType::Frequency
                  when .cubic_feet_per_second?, .cubic_feet_per_minute?, .cubic_feet_per_hour?, .cubic_meters_per_second?, .cubic_meters_per_minute?, .cubic_meters_per_hour?, .imperial_gallons_per_minute?, .milliliters_per_second?, .liters_per_second?, .liters_per_minute?, .liters_per_hour?, .us_gallons_per_minute?, .us_gallons_per_hour?
                    SensorType::Flow
                  when .percent?
                    SensorType::Level
                  when .no_units?
                    if object.name.includes? "count"
                      SensorType::Counter
                    end
                  end
    return nil unless sensor_type
    return nil if filter_type && sensor_type != filter_type

    unit = case object.unit
           when Nil
           when .degrees_fahrenheit?           then "[degF]"
           when .degrees_celsius?              then "Cel"
           when .degrees_kelvin?               then "K"
           when .pounds_force_per_square_inch? then "[psi]"
           when .volts?                        then "V"
           when .millivolts?                   then "mV"
           when .kilovolts?                    then "kV"
           when .megavolts?                    then "MV"
           when .milliamperes?                 then "mA"
           when .amperes?                      then "A"
           when .cubic_feet?                   then "[cft_i]"
           when .cubic_meters?                 then "m3"
           when .imperial_gallons?             then "[gal_br]"
           when .milliliters?                  then "ml"
           when .liters?                       then "l"
           when .us_gallons?                   then "[gal_us]"
           when .milliwatts?                   then "mW"
           when .watts?                        then "W"
           when .kilowatts?                    then "kW"
           when .megawatts?                    then "MW"
           when .watt_hours?                   then "Wh"
           when .kilowatt_hours?               then "kWh"
           when .megawatt_hours?               then "MWh"
           when .hertz?                        then "Hz"
           when .kilohertz?                    then "kHz"
           when .megahertz?                    then "MHz"
           when .cubic_feet_per_second?        then "[cft_i]/s"
           when .cubic_feet_per_minute?        then "[cft_i]/min"
           when .cubic_feet_per_hour?          then "[cft_i]/h"
           when .cubic_meters_per_second?      then "m3/s"
           when .cubic_meters_per_minute?      then "m3/min"
           when .cubic_meters_per_hour?        then "m3/h"
           when .imperial_gallons_per_minute?  then "[gal_br]/min"
           when .milliliters_per_second?       then "ml/s"
           when .liters_per_second?            then "l/s"
           when .liters_per_minute?            then "l/min"
           when .liters_per_hour?              then "l/h"
           when .us_gallons_per_minute?        then "[gal_us]/min"
           when .us_gallons_per_hour?          then "[gal_us]/h"
           end

    obj_value = object_value(object)
    value = case obj_value
            in String, Nil, ::Time, ::BACnet::PropertyIdentifier::PropertyType, Tuple(ObjectType, UInt32)
              nil
            in Bool
              obj_value ? 1.0 : 0.0
            in UInt64, Int64, Float32, Float64
              obj_value.to_f64
            end
    return nil if value.nil?

    Interface::Sensor::Detail.new(
      type: sensor_type,
      value: value,
      last_seen: object.changed.to_unix,
      mac: device_id.to_s,
      id: "#{object.object_type}[#{object.instance_id}]",
      name: "#{device.name}: #{object.name}",
      module_id: module_id,
      binding: object_binding(device_id, object),
      unit: unit
    )
  end

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    filter = type ? Interface::Sensor::SensorType.parse?(type) : nil

    if mac
      device_id = mac.to_u32?
      return NO_MATCH unless device_id
      device = get_device device_id
      return NO_MATCH unless device
      return device.objects.compact_map { |obj| to_sensor(device_id, device, obj, filter) }
    end

    matches = @mutex.synchronize do
      @devices.map do |(device_id, device)|
        device.objects.compact_map { |obj| to_sensor(device_id, device, obj, filter) }
      end
    end
    matches.flatten
  rescue error
    logger.warn(exception: error) { "searching for sensors" }
    NO_MATCH
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id
    device_id = mac.to_u32?
    return nil unless device_id
    device = get_device device_id
    return nil unless device

    # id should be in the format "object_type[instance_id]"
    obj_type_string, instance_id_string = id.split('[', 2)
    instance_id = instance_id_string.rchop.to_u32?
    return nil unless instance_id

    object_type = ObjectType.parse?(obj_type_string)
    return nil unless object_type

    object = get_object_details(device_id, instance_id, object_type)

    if object.changed < 1.minutes.ago
      begin
        object.sync_value(bacnet_client)
      rescue error
        logger.warn(exception: error) { "failed to obtain latest value for sensor at #{mac}.#{id}" }
      end
    end

    to_sensor(device_id, device, object)
  end

  @[Security(Level::Support)]
  def save_seen_devices
    define_setting(:known_devices, @seen_devices.values)
  end
end
