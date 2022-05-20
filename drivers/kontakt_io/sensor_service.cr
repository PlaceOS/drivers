require "placeos-driver"
require "./kio_cloud_models"
require "placeos-driver/interface/sensor"

class KontaktIO::SensorService < PlaceOS::Driver
  include Interface::Sensor

  descriptive_name "KontaktIO Sensor Service"
  generic_name :KontaktSensors
  description %(collects room occupancy data from KontaktIO)

  accessor kontakt_io : KontaktIO_1
  bind KontaktIO_1, :occupancy_cached_at, :update_cache

  default_settings({
    floor_mappings: {
      "KontaktIO_floor_id": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  @zone_lookup : Hash(String, Array(Int64)) = {} of String => Array(Int64)

  def on_load
    on_update
  end

  def on_update
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)

    lookup = Hash(String, Array(Int64)).new { |hash, key| hash[key] = [] of Int64 }
    @floor_mappings.each do |kontakt_floor_id, zones|
      begin
        kontakt_id = kontakt_floor_id.to_i64
        if building_id = zones[:building_id]
          lookup[building_id] << kontakt_id
        end
        lookup[zones[:level_id]] << kontakt_id
      rescue error
        logger.warn(exception: error) { "invalid floor mapping #{kontakt_floor_id}" }
      end
    end
    @zone_lookup = lookup
  end

  # ===================================
  # Caching sensor data
  # ===================================
  @occupancy_cache : Hash(Int64, RoomOccupancy) = {} of Int64 => RoomOccupancy

  protected def update_cache(_sub, _event)
    @occupancy_cache = Hash(Int64, RoomOccupancy).from_json kontakt_io.occupancy_cache.get.to_json
  end

  # ===================================
  # Sensor Interface functions
  # ===================================
  def sensor(mac : String, id : String? = nil) : Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id && mac.starts_with?("kontakt-")

    room = @occupancy_cache[mac.lchop("kontakt-").to_i64?]?
    return nil unless room

    case id
    when "people"
      build_sensor_details(room, :people_count)
    when "presence"
      build_sensor_details(room, :presence)
    end
  rescue error
    logger.warn(exception: error) { "checking for sensor" }
    nil
  end

  SENSOR_TYPES = {SensorType::PeopleCount, SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    if mac
      return NO_MATCH unless mac.starts_with?("kontakt-")
      room = @occupancy_cache[mac.lchop("kontakt-").to_i64?]?
    end

    if zone_id
      levels = @zone_lookup[zone_id]?
    end

    if room
      build_sensors(room, sensor_type)
    elsif levels
      matching = @occupancy_cache.values.select do |room|
        floor_id = room.floor_id
        floor_id.in?(levels) || @floor_mappings[floor_id.to_s]?.nil?
      end
      matching.flat_map { |room| build_sensors(room, sensor_type) }
    else
      @occupancy_cache.values.flat_map { |room| build_sensors(room, sensor_type) }
    end
  end

  protected def build_sensor_details(room : RoomOccupancy, sensor : SensorType) : Detail
    id = "people"
    value = case sensor
            when .people_count?
              room.occupancy.to_f64
            when .presence?
              id = "presence"
              room.occupancy > 0 ? 1.0 : 0.0
            else
              raise "sensor type unavailable: #{sensor}"
            end

    detail = Detail.new(
      type: sensor,
      value: value,
      last_seen: room.last_update.to_unix,
      mac: "kontakt-#{room.room_id}",
      id: id,
      name: "#{room.floor_name} #{room.room_name} (#{room.building_name})",
    )
    if zones = @floor_mappings[room.floor_id.to_s]?
      detail.level = zones[:level_id]
      detail.building = zones[:building_id]
    end
    detail
  end

  protected def build_sensors(room : RoomOccupancy, sensor : SensorType? = nil)
    if sensor
      [build_sensor_details(room, sensor)]
    else
      [
        build_sensor_details(room, :people_count),
        build_sensor_details(room, :presence),
      ]
    end
  end
end
