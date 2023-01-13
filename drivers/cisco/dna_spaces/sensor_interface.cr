class Cisco::DNASpaces
  IOT_SENSORS = {
    SensorType::Presence, SensorType::PeopleCount, SensorType::Humidity,
    SensorType::AirQuality, SensorType::SoundPressure, SensorType::Temperature,
  }
  NO_MATCH = [] of Interface::Sensor::Detail

  protected def to_sensors(zone_id, filter, device : IotTelemetry)
    if level_loc = device.location_mappings["FLOOR"]?
      if floorplan = @floorplan_mappings[level_loc]?
        building = floorplan["building"]?.as(String?)
        level = floorplan["level"]?.as(String?)
      end
    end

    sensors = [] of Interface::Sensor::Detail
    return sensors if zone_id && (building || level) && !zone_id.in?({building, level})

    formatted_mac = format_mac(device.device.mac_address)
    time = device.last_seen
    device_name = device.device.device_name.presence || device.device.id

    IOT_SENSORS.each do |type|
      next if filter && filter != type

      unit = nil
      value = nil
      binding = nil

      case type
      when SensorType::Presence
        if !(presence = device.presence).nil?
          value = presence ? 1.0 : 0.0
        end
      when SensorType::Humidity
        if humidity = device.humidity
          value = humidity
          unit = "%"
          binding = "#{formatted_mac}->humidity->humidityInPercentage"
        end
      when SensorType::AirQuality
        if air_quality = device.air_quality
          value = air_quality
          binding = "#{formatted_mac}->airQuality->airQualityIndex"
        end
      when SensorType::PeopleCount
        if count = device.people_count
          value = count.to_f
          binding = "#{formatted_mac}->tpData->peopleCount"
        end
      when SensorType::Temperature
        if temp = device.temperature
          value = temp
          unit = "Cel"
          binding = "#{formatted_mac}->temperature->temperatureInCelsius"
        end
      when SensorType::SoundPressure
        if noise = device.ambient_noise
          value = noise.to_f
          unit = "dB[SPL]" # NOTE:: this is a guess
        end
      else
        next
      end

      next unless value

      sensor = Interface::Sensor::Detail.new(
        type: type,
        value: value,
        last_seen: time,
        mac: formatted_mac,
        id: type.to_s,
        name: "#{device_name} #{device.device.type} (#{type})",
        module_id: module_id,
        binding: binding
      )

      sensor.building = building
      sensor.level = level
      sensors << sensor
    end

    sensors
  end

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    filter = type ? SensorType.parse(type) : nil
    return NO_MATCH if filter && !filter.in?(IOT_SENSORS)

    if mac
      mac = format_mac(mac)
      device = devices { |dev| dev[mac]? }
      return NO_MATCH unless device
      return case device
      in IotTelemetry
        to_sensors(zone_id, filter, device)
      in DeviceLocationUpdate
        NO_MATCH
      end
    end

    device_values = devices &.values
    device_values.flat_map do |device|
      case device
      in IotTelemetry
        to_sensors(zone_id, filter, device)
      in DeviceLocationUpdate
        NO_MATCH
      end
    end
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }

    return nil unless id
    mac = format_mac(mac)
    device = devices { |dev| dev[mac]? }
    return nil unless device

    filter = SensorType.parse(id)
    case device
    in IotTelemetry
      to_sensors(nil, filter, device).first?
    in DeviceLocationUpdate
    end
  end
end
