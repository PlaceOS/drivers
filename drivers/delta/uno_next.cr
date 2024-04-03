require "placeos-driver"
require "placeos-driver/interface/sensor"
require "./models/**"

struct Delta::Models::Object
  # re-open the object model
  @[JSON::Field(ignore: true)]
  property! building_zone : String

  @[JSON::Field(ignore: true)]
  property! level_zone : String

  @[JSON::Field(ignore: true)]
  property! device_id : UInt32
end

# documentation: https://isdweb.deltaww.com/resources/files/UNOnext_bacnet_user_guide.pdf

class Delta::UNOnext < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "Delta UNOnext Indoor Air Monitor"
  generic_name :UNOnext
  description %(collects sensor data from UNOnext sensors)

  default_settings({
    site_name:        "My Office",
    manager_mappings: [{
      building_zone: "zone_id_here",
      level_zone:    "zone_id_here",
      managers:      [107100, 107300],
    }],
    # seconds between polling
    poll_every: 10,
  })

  accessor delta_api : Delta_1

  def on_load
    on_update
  end

  record ManMap, building_zone : String, level_zone : String, managers : Array(UInt32) do
    include JSON::Serializable
  end

  def on_update
    @site_name = setting(String, :site_name)
    @manager_mappings = setting(Array(ManMap), :manager_mappings)

    poll_every = setting?(Int32, :poll_every) || 10

    @cached_data = Hash(String, Array(Detail)).new { |hash, key| hash[key] = [] of Detail }
    schedule.clear
    schedule.every(poll_every.seconds) { cache_sensor_data }
  end

  getter site_name : String = "My Office"
  getter manager_mappings : Array(ManMap) = [] of ManMap
  getter cached_data : Hash(String, Array(Detail)) = {} of String => Array(Detail)

  # ===================================
  # Sensor Interface functions
  # ===================================
  def sensor(mac : String, id : String? = nil) : Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id && mac.starts_with?("unonext-")

    device_id = mac.lchop("unonext-").to_u32?
    index = id.to_u32?
    return nil unless device_id && index

    build_sensor_details(device_id, index)
  rescue error
    logger.warn(exception: error) { "checking for sensor" }
    nil
  end

  SENSOR_TYPES = {
    0 => SensorType::Temperature,
    1 => SensorType::Humidity,
    2 => SensorType::PPM, # PM2.5 (particles smaller than 2.5)
    4 => SensorType::PPM, # CO2
    5 => SensorType::Illuminance,
    # 9 => SensorType::PPM, # O3
  }
  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    # skip processing where possible
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.values.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac.starts_with?("unonext-")
    end

    # grab the relevant values
    result = if zone_id
               cached_data[zone_id]? || [] of Detail
             else
               manager_mappings.flat_map do |man_map|
                 cached_data[man_map.level_zone]? || [] of Detail
               end
             end

    # filter them based on the request
    if sensor_type && mac
      result.reject! { |details| details.type != sensor_type || details.mac != mac }
    elsif sensor_type
      result.reject! { |details| details.type != sensor_type }
    elsif mac
      result.reject! { |details| details.mac != mac }
    end

    result
  end

  # ===================================
  # Helper functions
  # ===================================

  protected def build_sensor_details(device_id : UInt32, index : UInt32, building : String? = nil, level : String? = nil) : Detail?
    prop = Models::ValueProperty.from_json delta_api.get_object_value(@site_name, device_id, "analog-value", index).get.to_json
    return nil if (prop.out_of_service.try(&.value.as_i?) || 1) != 0

    value = prop.present_value.try do |pv|
      if string = pv.value.as_s?
        string.to_f?
      elsif int = pv.value.as_i?
        int.to_f
      end
    end
    return nil unless value

    case prop.units.try &.value
    when "°C"
      unit = "Cel"
      sensor = SensorType::Temperature
    when "%RH"
      sensor = SensorType::Humidity
    when "lx"
      unit = "lx"
      sensor = SensorType::Illuminance
    when "ppm"
      case prop.object_name.try(&.value.as_s)
      when .try(&.includes?("_C02"))
        modifier = "CO2"
        sensor = SensorType::PPM
      else
        modifier = "particle"
        sensor = SensorType::PPM
      end
    end
    return nil unless sensor

    Detail.new(
      modifier: modifier,
      type: sensor,
      value: value,
      last_seen: Time.utc.to_unix,
      mac: "unonext-#{device_id}",
      id: index.to_s,
      name: "UNONext #{device_id}.#{index} #{prop.display_name} #{prop.units.try &.value}",
      binding: "#{device_id}.#{index}",
      module_id: module_id,
      unit: unit,
      building: building,
      level: level,
    )
  rescue error
    logger.warn(exception: error) { "error requesting object value from #{device_id}.#{index}" }
    nil
  end

  NO_OBJECTS = [] of Models::Object

  def cache_sensor_data(zone_id : String? = nil, sensor : SensorType? = nil, device_id : UInt32? = nil) : Nil
    # grab all the UNONext manager objects
    site = site_name
    all_objects = manager_mappings.flat_map do |man_map|
      if zone = zone_id
        next NO_OBJECTS unless zone.in?({man_map.building_zone, man_map.level_zone})
      end

      man_map.managers.flat_map do |id|
        if device = device_id
          next NO_OBJECTS unless id == device
        end

        begin
          Array(Models::Object).from_json(delta_api.list_device_objects(site, id).get.to_json)
            .select(&.display_name.includes?("UnoNext"))
            .map do |obj|
              obj.building_zone = man_map.building_zone
              obj.level_zone = man_map.level_zone
              obj.device_id = id
              obj
            end
        rescue error
          logger.warn(exception: error) { "error requesting objects from manager #{id}" }
          NO_OBJECTS
        end
      end
    end

    # parse them into sensor data
    all_objects.each_slice(7) do |objects|
      SENSOR_TYPES.each do |index, type|
        next if sensor && sensor != type
        object = objects[index]

        if details = build_sensor_details(object.device_id, object.instance, object.building_zone, object.level_zone)
          self[details.binding] = details

          @cached_data[object.building_zone] << details
          @cached_data[object.level_zone] << details
        end
      end
    end
  end
end
