require "json"
require "oauth2"
require "placeos-driver"
require "placeos-driver/interface/locatable"
require "placeos-driver/interface/sensor"
require "./models"

class Vergesense::LocationService < PlaceOS::Driver
  include Interface::Locatable
  include Interface::Sensor

  descriptive_name "Vergesense Location Service"
  generic_name :VergesenseLocationService
  description %(collects desk booking data from the staff API and overlays Vergesense data for visualising on a map)

  accessor area_manager : AreaManagement_1
  accessor vergesense : Vergesense_1

  default_settings({
    floor_mappings: {
      "vergesense_building_id-floor_id": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  @zone_filter : Array(String) = [] of String
  @building_mappings : Hash(String, String?) = {} of String => String?

  def on_load
    on_update
  end

  def on_update
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)
    @zone_filter = @floor_mappings.values.map do |z|
      level = z[:level_id]
      @building_mappings[level] = z[:building_id]
      level
    end

    bind_floor_status
  end

  # ===================================
  # Bindings into Vergesense data
  # ===================================
  protected def bind_floor_status
    subscriptions.clear

    @floor_mappings.each do |floor_id, details|
      zone_id = details[:level_id]
      vergesense.subscribe(floor_id) do |_sub, payload|
        level_state_change(zone_id, Floor.from_json(payload))
      end
    end
  end

  # Zone_id => Floor
  @occupancy_mappings : Hash(String, Floor) = {} of String => Floor

  protected def level_state_change(zone_id, floor)
    @occupancy_mappings[zone_id] = floor
    area_manager.update_available({zone_id})
  rescue error
    logger.error(exception: error) { "error updating level #{zone_id} space changes" }
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "sensor incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "sensor incapable of tracking #{email} or #{username}" }
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "sensor incapable of tracking #{mac_address}" }
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Nil unless @zone_filter.includes?(zone_id)

    floor = @occupancy_mappings[zone_id]?
    return [] of Nil unless floor

    floor.spaces.compact_map do |space|
      loc_type = space.space_type == "desk" ? "desk" : "area"
      next if location.presence && location != loc_type

      people_count = space.people.try(&.count)

      if people_count && people_count > 0
        if env = space.environment
          humidity = env.humidity.value
          temperature = env.temperature.value
          iaq = env.iaq.try &.value
        end

        {
          location:    loc_type,
          at_location: people_count,
          map_id:      space.name,
          level:       zone_id,
          building:    @building_mappings[zone_id]?,
          capacity:    space.capacity,

          vergesense_space_id:   space.space_ref_id,
          vergesense_space_type: space.space_type,
          area_humidity:         humidity,
          area_temperature:      temperature,
          area_air_quality:      iaq,
        }
      end
    end
  end

  # ===================================
  # Sensor Interface functions
  # ===================================
  def sensor(mac : String, id : String? = nil) : Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id

    # https://crystal-lang.org/api/1.1.0/String.html#rpartition(search:Char%7CString):Tuple(String,String,String)-instance-method
    zone_id, _, space_id = mac.rpartition('-')
    return nil if zone_id.empty? || space_id.empty?

    floor = @occupancy_mappings[zone_id]?
    return nil unless floor

    floor_space = floor.spaces.find { |space| space.space_ref_id == space_id }
    return nil unless floor_space

    case id
    when "people"
      build_sensor_details(zone_id, floor, floor_space, :people_count)
    when "presence"
      build_sensor_details(zone_id, floor, floor_space, :presence)
    when "humidity"
      build_sensor_details(zone_id, floor, floor_space, :humidity)
    when "temp"
      build_sensor_details(zone_id, floor, floor_space, :temperature)
    when "air"
      build_sensor_details(zone_id, floor, floor_space, :air_quality)
    end
  rescue error
    logger.warn(exception: error) { "checking for sensor" }
    nil
  end

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence, SensorType::Humidity, SensorType::Temperature, SensorType::AirQuality}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    if mac
      level_zone, _, space_id = mac.rpartition('-')
      return NO_MATCH if zone_id && zone_id != level_zone || space_id.empty?
      zone_id = level_zone
    end

    return NO_MATCH if zone_id && !@occupancy_mappings.has_key?(zone_id)

    if space_id
      floor = @occupancy_mappings[zone_id]
      floor_space = floor.spaces.find { |space| space.space_ref_id == space_id }
      return NO_MATCH unless floor_space
      spaces = [{zone_id, floor, floor_space}]
    elsif zone_id
      floor = @occupancy_mappings[zone_id]
      spaces = floor.spaces.map { |space| {zone_id, floor, space} }
    else
      spaces = @occupancy_mappings.flat_map { |(zone, floor)|
        floor.spaces.map { |space| {zone, floor, space} }
      }
    end

    if sensor_type
      spaces.compact_map { |(zone, floor, space)| build_sensor_details(zone.not_nil!, floor, space, sensor_type) }
    else
      spaces.flat_map { |(zone, floor, space)| space_sensors(zone.not_nil!, floor, space) }.compact
    end
  end

  protected def build_sensor_details(zone_id : String, floor : Vergesense::Floor, space : Vergesense::Space, sensor : SensorType) : Detail?
    time = space.timestamp
    id = "people"
    limit_high = nil
    value = case sensor
            when .people_count?
              limit_high = (space.max_capacity || space.capacity).try &.to_f64
              space.people.try &.count.try &.to_f64
            when .presence?
              id = "presence"
              space.people.try &.count.try { |count| count > 0 ? 1.0 : 0.0 } || 0.0
            when .humidity?
              id = "humidity"
              time = space.environment.try &.timestamp
              space.environment.try &.humidity.value
            when .temperature?
              id = "temp"
              time = space.environment.try &.timestamp
              space.environment.try &.temperature.value
            when .air_quality?
              id = "air"
              time = space.environment.try &.timestamp
              space.environment.try(&.iaq.try(&.value))
            else
              raise "sensor type unavailable: #{sensor}"
            end
    return nil unless value

    detail = Detail.new(
      type: sensor,
      value: value,
      last_seen: (time || Time.utc).to_unix,
      mac: "#{zone_id}-#{space.space_ref_id}",
      id: id,
      name: "#{floor.name} #{space.name} (#{space.space_type})",
      limit_high: limit_high
    )
    detail.level = zone_id
    detail
  end

  protected def space_sensors(zone_id : String, floor : Vergesense::Floor, space : Vergesense::Space)
    [
      build_sensor_details(zone_id, floor, space, :people_count),
      build_sensor_details(zone_id, floor, space, :presence),
      build_sensor_details(zone_id, floor, space, :humidity),
      build_sensor_details(zone_id, floor, space, :temperature),
      build_sensor_details(zone_id, floor, space, :air_quality),
    ].compact!
  end
end
