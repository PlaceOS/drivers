require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./cayenne_lpp_models"
require "./webhook_models"

class Milesight::Webhook < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "Milesight Webhook Receiver"
  generic_name :Milesight_Webhook

  default_settings({
    debug: false,
  })

  def on_update
    @debug = setting?(Bool, :debug) || false
  end

  record Info, eui : String, name : String, updated_at : Time do
    include JSON::Serializable
  end

  @sensor_cache = Hash(String, Hash(Types, Item)).new { |hash, key| hash[key] = {} of Types => Item }
  @mutex : Mutex = Mutex.new(:reentrant)

  getter device_info : Hash(String, Info) = Hash(String, Info).new

  def receive_webhook(method : String, headers : Hash(String, Array(String)), body : String)
    logger.warn {
      "Received Webhook\n" +
        "Method: #{method.inspect}\n" +
        "Headers:\n#{headers.inspect}\n" +
        "Body:\n#{body.inspect}"
    } if @debug

    # Process the webhook payload as needed
    payload = WebhookPayload.from_json(body)
    items = process_data(payload.data)

    # cache sensor data
    dev_eui = payload.dev_eui

    @mutex.synchronize do
      info = Info.new(dev_eui, payload.device_name, payload.time)
      @device_info[dev_eui] = info

      items.each do |item|
        type = item.type
        next unless type
        @sensor_cache[dev_eui][type] = item

        value = item.value
        next if value.is_a?(Bytes)
        self[object_binding(info, item)] = value
      end
    end
  end

  protected def process_data(base64 : String)
    bytes = Base64.decode(base64)
    io = IO::Memory.new(bytes)
    io.read_bytes(Frame).items
  end

  # ======================
  # Sensor interface
  # ======================

  protected def object_binding(device : Info, item : Item) : String
    "#{device.eui}.#{item.type}"
  end

  protected def to_sensor(device : Info, item : Item, filter_type : SensorType? = nil) : Interface::Sensor::Detail?
    sensor_type = case item.type.as(Types)
                  when .temperature?
                    SensorType::Temperature
                  when .humidity?
                    SensorType::Humidity
                  when .battery?
                    SensorType::Level
                  when .people_counting?
                    SensorType::Counter
                  end
    return nil unless sensor_type
    return nil if filter_type && sensor_type != filter_type

    unit = case sensor_type
           when .temperature? then "Cel"
           end

    raw_val = item.value
    value = case raw_val
            when Float64
              raw_val
            when Int16, UInt32, UInt8
              raw_val.to_f64
            end
    return nil unless value

    Interface::Sensor::Detail.new(
      type: sensor_type,
      value: value,
      last_seen: device.updated_at.to_unix,
      mac: device.eui,
      id: item.type.to_s,
      name: "#{device.name}: #{item.type}",
      module_id: module_id,
      binding: object_binding(device, item),
      unit: unit
    )
  end

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    filter = type ? Interface::Sensor::SensorType.parse?(type) : nil

    if mac
      device = @device_info[mac]?
      return NO_MATCH unless device
      return @sensor_cache[mac].values.compact_map { |item| to_sensor(device, item, filter) }
    end

    matches = @mutex.synchronize do
      @device_info.map do |(device_id, device)|
        @sensor_cache[device_id].values.compact_map { |item| to_sensor(device, item, filter) }
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
    type = Types.parse(id) rescue nil
    return nil unless type
    device = @device_info[mac]?
    return nil unless device

    item = @sensor_cache[mac][type]?
    return nil unless item

    to_sensor(device, item)
  end
end
