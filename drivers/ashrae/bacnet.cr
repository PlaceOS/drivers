require "placeos-driver"
require "socket"
require "./bacnet_models"

class Ashrae::BACnet < PlaceOS::Driver
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
  })

  def websocket_headers
    dispatcher_key = setting?(String, :dispatcher_key)
    HTTP::Headers{
      "Authorization" => "Bearer #{dispatcher_key}",
      "X-Module-ID"   => module_id,
    }
  end

  getter! udp_server : UDPSocket
  getter! bacnet_client : ::BACnet::Client::IPv4
  getter! device_registry : ::BACnet::Client::DeviceRegistry

  alias DeviceInfo = ::BACnet::Client::DeviceRegistry::DeviceInfo

  @packets_processed : UInt64 = 0_u64
  @verbose_debug : Bool = false
  @bbmd_ip : Socket::IPAddress = Socket::IPAddress.new("127.0.0.1", 0xBAC0)
  @devices : Hash(UInt32, DeviceInfo) = {} of UInt32 => DeviceInfo
  @mutex : Mutex = Mutex.new(:reentrant)

  def on_load
    # We only use dispatcher for broadcast messages, a local port for primary comms
    server = UDPSocket.new
    server.bind "0.0.0.0", 0xBAC0
    @udp_server = server

    # Hook up the client to the transport
    client = ::BACnet::Client::IPv4.new
    client.on_transmit do |message, address|
      if address.address == Socket::IPAddress::BROADCAST
        logger.debug { "sending broadcase message #{message.inspect}" }
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
    @bbmd_ip = Socket::IPAddress.new(bbmd_ip, 0xBAC0) if bbmd_ip.presence
    @verbose_debug = setting?(Bool, :verbose_debug) || false
    schedule.in(5.seconds) { query_known_devices }

    perform_discovery if bbmd_ip.presence
  end

  def packets_processed
    @packets_processed
  end

  def connected
    bbmd_ip = setting?(String, :bbmd_ip)
    perform_discovery if bbmd_ip.presence
  end

  def devices
    device_registry.devices.map do |device|
      {
        name:        device.name,
        model_name:  device.model_name,
        vendor_name: device.vendor_name,

        ip_address: device.ip_address.to_s,
        network:    device.network,
        address:    device.address,
        id:         device.object_ptr.instance_number,

        objects: device.objects.map { |obj|
          value = begin
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
          {
            name: obj.name,
            type: obj.object_type,
            id:   obj.instance_id,

            unit:  obj.unit,
            value: value,
            seen:  obj.changed,
          }
        },
      }
    end
  end

  def query_known_devices
    devices = setting?(Array(DeviceAddress), :known_devices) || [] of DeviceAddress
    devices.each do |info|
      device_registry.inspect_device(info.address, info.identifier, info.net, info.addr)
    end
    "inspected #{devices.size} devices"
  end

  def update_values(device_id : UInt32)
    if device = @devices[device_id]?
      client = bacnet_client
      @mutex.synchronize do
        device.objects.each &.sync_value(client)
      end
      "updated #{device.objects.size} values"
    else
      raise "device #{device_id} not found"
    end
  end

  def perform_discovery : Nil
    bacnet_client.who_is
  end

  alias ObjectType = ::BACnet::ObjectIdentifier::ObjectType

  protected def get_object_details(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    device = @devices[device_id]
    device.objects.find { |obj| obj.object_ptr.object_type == object_type && obj.object_ptr.instance_number == instance_id }.not_nil!
  end

  def write_real(device_id : UInt32, instance_id : UInt32, value : Float32, object_type : ObjectType = ObjectType::AnalogValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value)
    )
    value
  end

  def write_double(device_id : UInt32, instance_id : UInt32, value : Float64, object_type : ObjectType = ObjectType::LargeAnalogValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value)
    )
    value
  end

  def write_unsigned_int(device_id : UInt32, instance_id : UInt32, value : UInt64, object_type : ObjectType = ObjectType::PositiveIntegerValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value)
    )
    value
  end

  def write_signed_int(device_id : UInt32, instance_id : UInt32, value : Int64, object_type : ObjectType = ObjectType::IntegerValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value)
    )
    value
  end

  def write_string(device_id : UInt32, instance_id : UInt32, value : String, object_type : ObjectType = ObjectType::CharacterStringValue)
    object = get_object_details(device_id, instance_id, object_type)
    bacnet_client.write_property(
      object.ip_address,
      ::BACnet::ObjectIdentifier.new(object_type, instance_id),
      ::BACnet::PropertyType::PresentValue,
      ::BACnet::Object.new.set_value(value)
    )
    value
  end

  protected def new_device_found(device)
    logger.debug { "new device found: #{device.name}, #{device.model_name} (#{device.vendor_name}) with #{device.objects.size} objects" }
    logger.debug { device.inspect } if @verbose_debug

    @devices[device.object_ptr.instance_number] = device
  end

  def received(data, task)
    # we should only be receiving broadcasted messages here
    protocol = IO::Memory.new(data).read_bytes(DispatchProtocol)

    logger.debug { "received message: #{protocol.message} #{protocol.ip_address}:#{protocol.id_or_port} (size #{protocol.data_size})" }

    if protocol.message.received?
      message = IO::Memory.new(protocol.data).read_bytes(::BACnet::Message::IPv4)
      bacnet_client.received message, @bbmd_ip
    end

    task.try &.success
  end
end
