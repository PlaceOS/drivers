require "placeos-driver"
require "placeos-driver/interface/sensor"
require "bacnet"
require "json"

# docs: https://bacnet.org/wp-content/uploads/sites/4/2022/08/Add-135-2016bj.pdf
# https://www.ashrae.org/file%20library/technical%20resources/standards%20and%20guidelines/standards%20addenda/135_2016_bj_20191118.pdfc

class Ashrae::BACnetSecureConnect < PlaceOS::Driver
  include Interface::Sensor

  generic_name :BACnet
  descriptive_name "BACnet Secure Connect"
  description "BACnet over secure websockets"

  uri_base "wss://server.domain.or.ip/hub"

  default_settings({
    _https_verify:      "none",
    _https_private_key: "-----BEGIN PRIVATE KEY-----",
    _https_client_cert: "-----BEGIN CERTIFICATE-----",
    verbose_debug:      false,
    poll_period:        3,
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

    # Initialize inspection semaphore
    MAX_CONCURRENT_INSPECTIONS.times { @inspection_semaphore.send(nil) }

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

    # Load known devices from settings and add to seen_devices if not already present
    devices = setting?(Array(DeviceConfig), :known_devices) || [] of DeviceConfig
    devices.each do |config|
      device_id = config.device_instance
      unless @seen_devices.has_key?(device_id)
        @seen_devices[device_id] = config.to_device
      end
    end
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
      logger.debug do
        if message.data_link.request_type.encapsulated_npdu?
          "sending message: #{message.application.class}"
        else
          "sending network message: #{message.data_link.request_type}"
        end
      end
      send message
    end

    # connection response handling
    client.on_control_info do |message|
      # Track the discovery of devices once the connection is established
      case message.data_link.request_type
      when .connect_accept?
        schedule.clear
        schedule.in(5.seconds) { query_known_devices }
        schedule.every(60.seconds) { bacnet_client.heartbeat! }

        poll_period = setting?(UInt32, :poll_period) || 3
        if poll_period > 0
          # Stagger device polling across the poll period to avoid CPU spikes
          keys = @mutex.synchronize { @devices.keys }
          device_count = keys.size
          
          if device_count > 0
            delay_between_devices = (poll_period.minutes.total_seconds / device_count).seconds
            
            keys.each_with_index do |device_id, index|
              initial_delay = delay_between_devices * index
              
              schedule.in(initial_delay) do
                schedule.every(poll_period.minutes) do
                  if index == 0
                    logger.debug { "--- Polling #{device_count} BACnet devices (every #{poll_period} minutes, #{delay_between_devices.total_seconds.round(1)}s between devices)" }
                  end
                  logger.debug { "Polling device #{device_id}" }
                  poll_device(device_id)
                end
              end
            end
          end
        end

        perform_discovery
      end
    end

    @bacnet_client = client
    client.connect!
  end

  def disconnected
    @bacnet_client = nil
    schedule.clear
  end

  protected getter! bacnet_client : ::BACnet::Client::SecureConnect

  # Simple device configuration for settings (no recursive structure)
  class DeviceConfig
    include JSON::Serializable

    def initialize(@device_instance : UInt32, @vmac : String, @network : UInt16? = nil, @address : String? = nil)
    end

    property device_instance : UInt32
    property vmac : String
    property network : UInt16?
    property address : String?

    # Convert to DiscoveryStore::Device
    def to_device : ::BACnet::DiscoveryStore::Device
      ::BACnet::DiscoveryStore::Device.new(
        device_instance: @device_instance,
        vmac: @vmac,
        network: @network,
        address: @address
      )
    end

    # Create from DiscoveryStore::Device
    def self.from_device(device : ::BACnet::DiscoveryStore::Device) : DeviceConfig
      new(
        device_instance: device.device_instance,
        vmac: device.vmac || "",
        network: device.network,
        address: device.address
      )
    end
  end

  # Object tracking for BACnet objects
  class ObjectInfo
    property object_ptr : ::BACnet::ObjectIdentifier
    property name : String = ""
    property unit : ::BACnet::Unit?
    property value : ::BACnet::Object?
    property changed : Time = Time.utc

    def initialize(@object_ptr)
    end

    def object_type
      @object_ptr.object_type
    end

    def instance_id
      @object_ptr.instance_number
    end

    def sync_value(client : ::BACnet::Client::SecureConnect, vmac : Bytes)
      result = client.read_property(@object_ptr, ::BACnet::PropertyIdentifier::PropertyType::PresentValue, nil, nil, nil, link_address: vmac).get
      @value = client.parse_complex_ack(result)[:objects][0]?.try(&.as(::BACnet::Object))
      @changed = Time.utc
      @value
    rescue error
      raise error
    end
  end

  # Device tracking
  class DeviceInfo
    property device_instance : UInt32
    property vmac : Bytes
    property network : UInt16?
    property address : String?
    property name : String = ""
    property vendor_name : String = ""
    property model_name : String = ""
    property objects : Array(ObjectInfo) = [] of ObjectInfo

    def initialize(@device_instance, @vmac)
    end

    def object_ptr
      ::BACnet::ObjectIdentifier.new(:device, @device_instance)
    end

    def link_address_friendly
      @vmac.hexstring
    end
  end

  alias ObjectType = ::BACnet::ObjectIdentifier::ObjectType

  # Object types that have present values we can read
  OBJECTS_WITH_VALUES = [
    ObjectType::AnalogInput, ObjectType::AnalogOutput, ObjectType::AnalogValue,
    ObjectType::BinaryInput, ObjectType::BinaryOutput, ObjectType::BinaryValue,
    ObjectType::MultiStateInput, ObjectType::MultiStateOutput, ObjectType::MultiStateValue,
    ObjectType::IntegerValue, ObjectType::LargeAnalogValue, ObjectType::PositiveIntegerValue,
    ObjectType::Accumulator, ObjectType::PulseConverter, ObjectType::Loop,
    ObjectType::Calendar, ObjectType::Command, ObjectType::LoadControl, ObjectType::AccessDoor,
    ObjectType::LifeSafetyPoint, ObjectType::LifeSafetyZone, ObjectType::Schedule,
    ObjectType::DatetimeValue, ObjectType::BitstringValue, ObjectType::OctetstringValue,
    ObjectType::DateValue, ObjectType::DatetimePatternValue, ObjectType::TimePatternValue,
    ObjectType::DatePatternValue, ObjectType::AlertEnrollment, ObjectType::Channel,
    ObjectType::LightingOutput, ObjectType::CharacterStringValue, ObjectType::TimeValue,
  ]

  # Rate limiting for device inspections
  MAX_CONCURRENT_INSPECTIONS = 5
  @inspection_semaphore : Channel(Nil) = Channel(Nil).new(MAX_CONCURRENT_INSPECTIONS)

  @packets_processed : UInt64 = 0_u64
  @seen_devices : Hash(UInt32, ::BACnet::DiscoveryStore::Device) = {} of UInt32 => ::BACnet::DiscoveryStore::Device
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
      id:      device.device_instance,

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
    @mutex.synchronize { @devices.values }.map { |device| device_details device }
  end

  def query_known_devices
    # Query all devices in seen_devices (which includes loaded known_devices from on_update)
    count = 0
    @seen_devices.each_value do |info|
      device_id = info.device_instance
      # Get VMAC bytes from the device info
      if vmac_hex = info.vmac
        vmac = vmac_hex.hexbytes
        logger.debug { "inspecting #{vmac.hexstring} - #{device_id}" }
        spawn { inspect_device_with_limit(device_id, vmac) }
        count += 1
      end
    end
    "inspecting #{count} devices"
  end

  # Wrapper to rate limit concurrent device inspections
  protected def inspect_device_with_limit(device_id : UInt32, vmac : Bytes)
    @inspection_semaphore.receive  # Acquire semaphore
    begin
      inspect_device(device_id, vmac)
    ensure
      @inspection_semaphore.send(nil)  # Release semaphore
    end
  end

  # Custom device inspection - replaces the old DeviceRegistry.inspect_device
  protected def inspect_device(device_id : UInt32, vmac : Bytes)
    # Check if we already have this device
    existing = @mutex.synchronize { @devices[device_id]? }
    return if existing && !existing.objects.empty?

    device = existing || DeviceInfo.new(device_id, vmac)
    client = bacnet_client
    object_id = ::BACnet::ObjectIdentifier.new(:device, device_id)

    # Query device properties
    begin
      result = client.read_property(object_id, ::BACnet::PropertyIdentifier::PropertyType::ObjectName, nil, nil, nil, link_address: vmac).get
      device.name = client.parse_complex_ack(result)[:objects][0].value.as(String)
    rescue error
      logger.debug(exception: error) { "Failed to read object_name for device [#{device_id}]" }
    end

    begin
      result = client.read_property(object_id, ::BACnet::PropertyIdentifier::PropertyType::VendorName, nil, nil, nil, link_address: vmac).get
      device.vendor_name = client.parse_complex_ack(result)[:objects][0].value.as(String)
    rescue error
      logger.debug(exception: error) { "Failed to read vendor_name for device [#{device_id}]" }
    end

    begin
      result = client.read_property(object_id, ::BACnet::PropertyIdentifier::PropertyType::ModelName, nil, nil, nil, link_address: vmac).get
      device.model_name = client.parse_complex_ack(result)[:objects][0].value.as(String)
    rescue error
      logger.debug(exception: error) { "Failed to read model_name for device [#{device_id}]" }
    end

    # Query object list
    begin
      result = client.read_property(object_id, ::BACnet::PropertyIdentifier::PropertyType::ObjectList, 0, nil, nil, link_address: vmac).get
      obj_list_item = client.parse_complex_ack(result)[:objects][0]

      # Handle string vs integer for object count
      max_objects = if obj_list_item.tag == 7 # CharacterString
                      string_value = obj_list_item.to_encoded_string
                      logger.warn { "Device [#{device_id}] returned string '#{string_value}' for ObjectList[0]" }
                      string_value.to_u64? || 0_u64
                    else
                      obj_list_item.to_u64
                    end

      # Sanity check
      if max_objects > 10_000
        logger.warn { "Device [#{device_id}] reports #{max_objects} objects - too many, skipping" }
        return
      end

      logger.debug { "Scanning #{max_objects} objects on device [#{device_id}]" }

      # Scan objects
      failed = 0
      (2..max_objects).each do |index|
        begin
          result = client.read_property(object_id, ::BACnet::PropertyIdentifier::PropertyType::ObjectList, index, nil, nil, link_address: vmac).get
          obj_id = client.parse_complex_ack(result)[:objects][0].to_object_id

          # Skip device objects (sub-devices)
          obj_type = obj_id.object_type
          next if obj_type && obj_type.device?

          # Create object info
          obj_info = ObjectInfo.new(obj_id)

          # Try to get object name
          begin
            name_result = client.read_property(obj_id, ::BACnet::PropertyIdentifier::PropertyType::ObjectName, nil, nil, nil, link_address: vmac).get
            obj_info.name = client.parse_complex_ack(name_result)[:objects][0].value.as(String)
          rescue
            obj_info.name = "(unnamed)"
          end

          # Try to get units if applicable
          if OBJECTS_WITH_VALUES.includes?(obj_type)
            begin
              unit_result = client.read_property(obj_id, ::BACnet::PropertyIdentifier::PropertyType::Units, nil, nil, nil, link_address: vmac).get
              unit_value = client.parse_complex_ack(unit_result)[:objects][0].to_i
              obj_info.unit = ::BACnet::Unit.new(unit_value)
            rescue
              # Units not available
            end
          end

          device.objects << obj_info

          # Yield periodically to prevent blocking other fibers
          Fiber.yield if index % 10 == 0
        rescue error
          logger.trace(exception: error) { "Failed to read object at index #{index}" }
          failed += 1
          break if failed > 2
        end
      end
    rescue error
      logger.debug(exception: error) { "Failed to read object_list for device [#{device_id}]" }
    end

    # Store the device
    @mutex.synchronize { @devices[device_id] = device }
    new_device_found(device)
  rescue error
    logger.error(exception: error) { "Failed to inspect device #{device_id}" }
  end

  def poll_device(device_id : UInt32)
    device = get_device(device_id)
    return false unless device

    client = bacnet_client
    vmac = device.vmac
    objects = @mutex.synchronize { device.objects.dup }
    objects.each do |obj|
      next unless obj.object_type.in?(OBJECTS_WITH_VALUES)
      name = object_binding(device_id, obj)
      queue(name: name, priority: 0, timeout: 500.milliseconds) do |task|
        spawn_action(task) do
          obj.sync_value(client, vmac)
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

  def update_value(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    device = get_device(device_id).not_nil!
    obj = get_object_details(device_id, instance_id, object_type)
    name = object_binding(device_id, obj)

    queue(name: name, priority: 50) do |task|
      spawn_action(task) do
        obj.sync_value(bacnet_client, device.vmac)
        self[name] = object_value(obj)
      end
    end
  end

  protected def get_object_details(device_id : UInt32, instance_id : UInt32, object_type : ObjectType)
    device = get_device(device_id).not_nil!
    device.objects.find { |obj| obj.object_ptr.object_type == object_type && obj.object_ptr.instance_number == instance_id }.not_nil!
  end

  def write_real(device_id : UInt32, instance_id : UInt32, value : Float32, object_type : ObjectType = ObjectType::AnalogValue)
    device = get_device(device_id).not_nil!

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  def write_double(device_id : UInt32, instance_id : UInt32, value : Float64, object_type : ObjectType = ObjectType::LargeAnalogValue)
    device = get_device(device_id).not_nil!

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  def write_unsigned_int(device_id : UInt32, instance_id : UInt32, value : UInt64, object_type : ObjectType = ObjectType::PositiveIntegerValue)
    device = get_device(device_id).not_nil!

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  def write_signed_int(device_id : UInt32, instance_id : UInt32, value : Int64, object_type : ObjectType = ObjectType::IntegerValue)
    device = get_device(device_id).not_nil!

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  def write_string(device_id : UInt32, instance_id : UInt32, value : String, object_type : ObjectType = ObjectType::CharacterStringValue)
    device = get_device(device_id).not_nil!

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          ::BACnet::Object.new.set_value(value),
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  def write_binary(device_id : UInt32, instance_id : UInt32, value : Bool, object_type : ObjectType = ObjectType::BinaryValue)
    val = value ? 1 : 0
    device = get_device(device_id).not_nil!
    val = ::BACnet::Object.new.set_value(val)
    val.short_tag = 9_u8

    queue(priority: 99) do |task|
      spawn_action(task) do
        bacnet_client.write_property(
          ::BACnet::ObjectIdentifier.new(object_type, instance_id),
          ::BACnet::PropertyIdentifier::PropertyType::PresentValue,
          val,
          link_address: device.vmac,
        ).get
      end
    end
    value
  end

  protected def new_device_found(device)
    logger.debug { "new device found: #{device.name}, #{device.model_name} (#{device.vendor_name}) with #{device.objects.size} objects" }
    logger.debug { device.inspect } if @verbose_debug

    @mutex.synchronize { @devices[device.device_instance] = device }

    device_id = device.device_instance
    device.objects.each { |obj| self[object_binding(device_id, obj)] = object_value(obj) }
  end

  protected def object_binding(device_id, obj)
    "#{device_id}.#{obj.object_type}[#{obj.instance_id}]"
  end

  def received(bytes, task)
    # will be a no-op, just here in case
    task.try &.success

    message = begin
      IO::Memory.new(bytes).read_bytes(::BACnet::Message::Secure)
    rescue error
      logger.warn(exception: error) { "error parsing bacnet packet: 0x#{bytes.hexstring}" }
      raise error
    end

    logger.debug do
      if message.data_link.request_type.encapsulated_npdu?
        "received message: #{message.application.class}"
      else
        "received network message: #{message.data_link.request_type}"
      end
    end

    # Let the client handle the message (important for promise resolution)
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
      vmac = message.data_link.source_vmac
      if vmac && network.source_specifier
        addr = network.source_address
        net = network.source.network
        device = message.objects.find { |obj| obj.tag == 1 }.not_nil!.to_object_id.instance_number
        # prop = message.objects.find { |obj| obj.tag == 2 }
        @seen_devices[device] = ::BACnet::DiscoveryStore::Device.new(
          device_instance: device,
          vmac: vmac.hexstring,
          network: net,
          address: addr
        )
      end
    end

    if network && is_iam
      vmac = message.data_link.source_vmac
      if vmac
        details = bacnet_client.parse_i_am(message)
        device = details[:object_id].instance_number
        @seen_devices[device] = ::BACnet::DiscoveryStore::Device.new(
          device_instance: device,
          vmac: vmac.hexstring,
          network: details[:network],
          address: details[:address]
        )
      end
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
        object.sync_value(bacnet_client, device.vmac)
      rescue error
        logger.warn(exception: error) { "failed to obtain latest value for sensor at #{mac}.#{id}" }
      end
    end

    to_sensor(device_id, device, object)
  end

  @[Security(Level::Support)]
  def save_seen_devices
    configs = @seen_devices.values.map { |device| DeviceConfig.from_device(device) }
    define_setting(:known_devices, configs)
  end
end
