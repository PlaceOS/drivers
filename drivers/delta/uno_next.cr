require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./models/**"

# documentation: https://isdweb.deltaww.com/resources/files/UNOnext_bacnet_user_guide.pdf

class Delta::UNOnext < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "UNOnext Indoor Air Quality Monitor"
  generic_name :UNOnext
  description %(collects sensor data from UNOnext sensors)

  default_settings({
    site_name: "My Office",
  })

  accessor delta_api : Delta_1

  def on_load
    schedule.every(1.minute) { cache_sensor_data }
    on_update
  end

  def on_update
    @site_name = setting(String, :site_name)
  end

  getter site_name : String = "My Office"

  # ===================================
  # Sensor Interface functions
  # ===================================
  def sensor(mac : String, id : String? = nil) : Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id && mac.starts_with?("unonext-")

    device_id = mac.lchop("unonext-").to_u32?
    index = id.to_i?
    return nil unless device_id && index

    type = SENSOR_TYPES[index]?
    return nil unless type

    build_sensor_details(type, device_id, index)
  rescue error
    logger.warn(exception: error) { "checking for sensor" }
    nil
  end

  SENSOR_TYPES = {
    0 => SensorType::Temperature,
    1 => SensorType::Humidity,
    4 => SensorType::PPM, # CO2
    5 => SensorType::Illuminance,
    9 => SensorType::PPM, # O3
  }
  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.values.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac.starts_with?("unonext-")
      device_id = mac.lchop("unonext-").to_u32?
    end

    build_sensors(sensor_type, device_id)
  end

  # ===================================
  # Helper functions
  # ===================================

  protected def build_sensor_details(sensor : SensorType, device_id : UInt32, index : Int32) : Detail?
    prop = Models::ValueProperty.from_json delta_api.get_object_value(@site_name, device_id, "analog-input", index).get.to_json
    return nil if (prop.out_of_service.try(&.value.as_i) || 0) != 0

    value = prop.present_value.try &.value.as_f
    return nil unless value

    case prop.units.try &.value
    when "°C"
      unit = "Cel"
    end

    Detail.new(
      type: sensor,
      value: value,
      last_seen: Time.utc.to_unix,
      mac: "unonext-#{device_id}",
      id: index.to_s,
      name: "UNONext #{device_id}.#{index} #{prop.display_name} #{prop.units.try &.value}",
      binding: "#{device_id}.#{index}",
      module_id: module_id,
      unit: unit
    )
  end

  protected def device_sensors(device_id : UInt32, sensor_type : SensorType? = nil)
    SENSOR_TYPES.compact_map do |index, type|
      next if sensor_type && type != sensor_type
      build_sensor_details(type, device_id, index)
    end
  end

  protected def build_sensors(sensor_type : SensorType? = nil, device_id : UInt32? = nil)
    if device_id
      # get the sensor data from the one device
      device_sensors device_id, sensor_type
    else
      # use cache data
      device_ids = status?(Array(UInt32), "device_ids")
      return NO_MATCH unless device_ids

      device_ids.flat_map do |id|
        SENSOR_TYPES.compact_map do |index, type|
          next if sensor_type && type != sensor_type
          status?(Detail, "#{id}.#{index}")
        end
      end
    end
  end

  def cache_sensor_data
    # grab all the UNONext devices and pull the sensor data from them
    device_ids = delta_api.list_devices(@site_name).get.as_a.compact_map do |dev|
      dev = dev.as_h
      if dev["display_name"].as_s == "UNONext"
        dev["id"].as_i64.to_u32
      end
    end

    self["device_ids"] = device_ids
    cached = 0

    device_ids.each do |id|
      begin
        device_sensors(id).each do |sensor|
          cached += 1
          self[sensor.binding] = sensor
        end
      rescue error
        logger.warn(exception: error) { "error fetching sensor id #{id}" }
      end
    end

    cached
  end
end
