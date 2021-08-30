require "placeos-driver"
require "placeos-driver/interface/sensor"
require "socket"
require "./bacnet_models"

class Ashrae::BACnet < PlaceOS::Driver
  include Interface::Sensor

  generic_name :BACnet
  descriptive_name "BACnet Connector"
  description %(makes BACnet data available to other drivers in PlaceOS)

  # Hookup dispatch to the BACnet BBMD device
  uri_base "ws://dispatch/api/server/udp_dispatch?port=47808&accept=192.168.0.1"

  default_settings({
    dispatcher_key: "secret",
    bbmd_ip:        "192.168.0.1",
    known_devices:  [{
      ip:   "192.168.86.25",
      id:   389999,
      net:  0x0F0F,
      addr: "0A",
    }],
    verbose_debug: false,
    poll_period:   3,
  })

  def websocket_headers
    dispatcher_key = setting?(String, :dispatcher_key)
    HTTP::Headers{
      "Authorization" => "Bearer #{dispatcher_key}",
      "X-Module-ID"   => module_id,
    }
  end

  protected getter! udp_server : UDPSocket
  protected getter! bacnet_client : ::BACnet::Client::IPv4
  protected getter! device_registry : ::BACnet::Client::DeviceRegistry

  alias DeviceInfo = ::BACnet::Client::DeviceRegistry::DeviceInfo

  @packets_processed : UInt64 = 0_u64
  @verbose_debug : Bool = false
  @bbmd_ip : Socket::IPAddress = Socket::IPAddress.new("127.0.0.1", 0xBAC0)
  @devices : Hash(UInt32, DeviceInfo) = {} of UInt32 => DeviceInfo
  @mutex : Mutex = Mutex.new(:reentrant)
  @bbmd_forwarding : Array(UInt8) = [] of UInt8
  @seen_devices : Hash(UInt32, DeviceAddress) = {} of UInt32 => DeviceAddress

  protected def get_device(device_id : UInt32)
    @mutex.synchronize { @devices[device_id]? }
  end

  def on_load
    # We only use dispatcher for broadcast messages, a local port for primary comms
    server = UDPSocket.new
    server.bind "0.0.0.0", 0xBAC0
    @udp_server = server

    # Hook up the client to the transport
    client = ::BACnet::Client::IPv4.new
    client.on_transmit do |message, address|
      if address.address == Socket::IPAddress::BROADCAST
        if @bbmd_forwarding.size == 4
          message.data_link.request_type = ::BACnet::Message::IPv4::Request::ForwardedNPDU
          message.data_link.address.ip1 = @bbmd_forwarding[0]
          message.data_link.address.ip2 = @bbmd_forwarding[1]
          message.data_link.address.ip3 = @bbmd_forwarding[2]
          message.data_link.address.ip4 = @bbmd_forwarding[3]
          message.data_link.address.port = 47808_u16
        end

        logger.debug { "sending broadcase message #{message.inspect}" }

        # send to the known devices (in case BBMD does not forward message)
        devices = setting?(Array(DeviceAddress), :known_devices) || [] of DeviceAddress
        devices.each do |dev|
          begin
            server.send message, to: dev.address
          rescue error
            logger.warn(exception: error) { "error sending message to #{dev.address}" }
          end
        end

        # Send this message to the BBMD
        message.data_link.request_type = ::BACnet::Message::IPv4::Request::DistributeBroadcastToNetwork
        payload = DispatchProtocol.new
        payload.message = DispatchProtocol::MessageType::WRITE
        payload.ip_address = @bbmd_ip.address
        payload.id_or_port = @bbmd_ip.port.to_u64
        payload.data = message.to_slice
        transport.send payload.to_slice
      else
        server.send message, to: address
      end
    end
    @bacnet_client = client

    # Track the discovery of devices
    registry = ::BACnet::Client::DeviceRegistry.new(client)
    registry.on_new_device { |device| new_device_found(device) }
    @device_registry = registry

    spawn { process_data(server, client) }
    on_update
  end

  # This is our input read loop, grabs the incoming data and pumps it to our client
  protected def process_data(server, client)
    loop do
      break if server.closed?
      bytes, client_addr = server.receive

      begin
        message = IO::Memory.new(bytes).read_bytes(::BACnet::Message::IPv4)
        client.received message, client_addr
        @packets_processed += 1_u64
      rescue error
        logger.warn(exception: error) { "error parsing BACnet packet from #{client_addr}: #{bytes.to_slice.hexstring}" }
      end
    end
  end

  def on_unload
    udp_server.close
  end

  def on_update
    bbmd_ip = setting?(String, :bbmd_ip) || ""
    bbmd_forwarding = setting?(String, :bbmd_forwarding) || ""

    @bbmd_forwarding = bbmd_forwarding.strip.split(".").select(&.presence).map(&.to_u8)
    @bbmd_ip = Socket::IPAddress.new(bbmd_ip, 0xBAC0) if bbmd_ip.presence
    @verbose_debug = setting?(Bool, :verbose_debug) || false

    schedule.clear
    schedule.in(5.seconds) { query_known_devices }

    poll_period = setting?(UInt32, :poll_period) || 3
    schedule.every(poll_period.minutes) do
      keys = @mutex.synchronize { @devices.keys }
      keys.each { |device_id| poll_device(device_id) }
    end

    perform_discovery if bbmd_ip.presence
  end

  def packets_processed
    @packets_processed
  end

  def connected
    bbmd_ip = setting?(String, :bbmd_ip)
    perform_discovery if bbmd_ip.presence
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
    in Nil, Bool, UInt64, Int64, Float32, Float64, String
      val
    end
  rescue
    nil
  end

  protected def device_details(device)
    {
      name:        device.name,
      model_name:  device.model_name,
      vendor_name: device.vendor_name,

      ip_address: device.ip_address.to_s,
      network:    device.network,
      address:    device.address,
      id:         device.object_ptr.instance_number,

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
      device_registry.inspect_device(info.address, info.identifier, info.net, info.addr)
    end
    devices = setting?(Array(DeviceAddress), :known_devices) || [] of DeviceAddress
    devices.each do |info|
      if id = info.id
        next if id.in? sent
        sent << id
        device_registry.inspect_device(info.address, info.identifier, info.net, info.addr)
      end
    end
    "inspected #{sent.size} devices"
  end

  def poll_device(device_id : UInt32)
    device = get_device(device_id)
    return false unless device

    client = bacnet_client
    @mutex.synchronize do
      device.objects.each do |obj|
        next unless obj.object_type.in?(::BACnet::Client::DeviceRegistry::OBJECTS_WITH_VALUES)
        obj.sync_value(client)
        self[object_binding(device_id, obj)] = object_value(obj)
      end
    end
    true
  end

  # Performs a WhoIs discovery against the BACnet network
  def perform_discovery : Nil
    bacnet_client.who_is
  end

  alias ObjectType = ::BACnet::ObjectIdentifier::ObjectType

  def update_value(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    obj = get_object_details(device_id, instance_id, object_type)
    obj.sync_value(bacnet_client)
    self[object_binding(device_id, obj)] = object_value(obj)
  end

  protected def get_object_details(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    device = get_device(device_id).not_nil!
    device.objects.find { |obj| obj.object_ptr.object_type == object_type && obj.object_ptr.instance_number == instance_id }.not_nil!
  end

  def write_real(device_id : UInt32, instance_id : UInt32, value : Float32, object_type : ObjectType = ObjectType::AnalogValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value),
      network: object.network,
      address: object.address
    )
    value
  end

  def write_double(device_id : UInt32, instance_id : UInt32, value : Float64, object_type : ObjectType = ObjectType::LargeAnalogValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value),
      network: object.network,
      address: object.address
    )
    value
  end

  def write_unsigned_int(device_id : UInt32, instance_id : UInt32, value : UInt64, object_type : ObjectType = ObjectType::PositiveIntegerValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value),
      network: object.network,
      address: object.address
    )
    value
  end

  def write_signed_int(device_id : UInt32, instance_id : UInt32, value : Int64, object_type : ObjectType = ObjectType::IntegerValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value),
      network: object.network,
      address: object.address
    )
    value
  end

  def write_string(device_id : UInt32, instance_id : UInt32, value : String, object_type : ObjectType = ObjectType::CharacterStringValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value),
      network: object.network,
      address: object.address
    )
    value
  end

  def write_binary(device_id : UInt32, instance_id : UInt32, value : Bool, object_type : ObjectType = ObjectType::BinaryValue)
    val = value ? 1 : 0
    object = get_object_details(device_id, instance_id, object_type)
    val = ::BACnet::Object.new.set_value(val)
    val.short_tag = 9_u8
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      val,
      network: object.network,
      address: object.address
    )
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

  def received(data, task)
    # we should only be receiving broadcasted messages here
    protocol = IO::Memory.new(data).read_bytes(DispatchProtocol)

    logger.debug { "received message: #{protocol.message} #{protocol.ip_address}:#{protocol.id_or_port} (size #{protocol.data_size})" }

    if protocol.message.received?
      message = IO::Memory.new(protocol.data).read_bytes(::BACnet::Message::IPv4)
      logger.debug { "dispatch sent:\n#{message.inspect}" } if @verbose_debug
      bacnet_client.received message, @bbmd_ip

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
        ip = if message.data_link.request_type.forwarded_npdu?
               ip_add = message.data_link.address
               "#{ip_add.ip1}.#{ip_add.ip2}.#{ip_add.ip3}.#{ip_add.ip4}"
             else
               protocol.ip_address
             end
        if network.source_specifier
          addr = network.source_address
          net = network.source.network
        end
        device = message.objects.find { |obj| obj.tag == 1 }.not_nil!.to_object_id.instance_number
        # prop = message.objects.find { |obj| obj.tag == 2 }
        @seen_devices[device] = DeviceAddress.new(ip, device, net, addr)
      end

      if network && is_iam
        ip = if message.data_link.request_type.forwarded_npdu?
               ip_add = message.data_link.address
               "#{ip_add.ip1}.#{ip_add.ip2}.#{ip_add.ip3}.#{ip_add.ip4}"
             else
               protocol.ip_address
             end
        details = ::BACnet::Client::Message::IAm.parse(message)
        device = details[:object_id].instance_number
        @seen_devices[device] = DeviceAddress.new(ip, device, details[:network], details[:address])
      end
    end

    task.try &.success
  end

  def seen_devices
    @seen_devices
  end

  # ======================
  # Sensor interface
  # ======================

  protected def to_sensor(device_id, device, object, filter_type = nil) : Interface::Sensor::Detail?
    sensor_type = case object.unit
                  when Nil
                    # required for case statement to work
                  when .degrees_fahrenheit?, .degrees_celsius?, .degrees_kelvin?
                    if object.name.includes? "air"
                      SensorType::AmbientTemp
                    else
                      SensorType::Temperature
                    end
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
      binding: object_binding(device_id, object)
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
end
