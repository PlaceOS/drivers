require "placeos-driver"
require "./kio_cloud_models"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/locatable"

class KontaktIO::SensorService < PlaceOS::Driver
  include Interface::Sensor
  include Interface::Locatable

  descriptive_name "KontaktIO Sensor Service"
  generic_name :KontaktSensors
  description %(collects room occupancy data from KontaktIO)

  accessor kontakt_io : KontaktIO_1
  bind KontaktIO_1, :occupancy_cached_at, :update_cache

  accessor staff_api : StaffAPI_1
  accessor location_service : LocationServices_1

  default_settings({
    floor_mappings: {
      "KontaktIO_floor_id": {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },

    return_empty_spaces: true,
  })

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  @zone_lookup : Hash(String, Array(Int64)) = {} of String => Array(Int64)

  def on_update
    @return_empty_spaces = setting?(Bool, :return_empty_spaces) || false
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

  # System id => Map ID
  getter system_map_ids : Hash(String, String) do
    building_zone = location_service.building_id.get.as_s
    map_ids = {} of String => String
    staff_api.systems(zone_id: building_zone).get.as_a.each do |sys|
      map_id = sys["map_id"]?.try(&.as_s?)
      next unless map_id
      map_ids[sys["id"].as_s] = map_id
    end
    map_ids
  end

  # KIO room id => Map ID
  getter map_ids : Hash(Int64, String) do
    ids = {} of Int64 => String
    system_map_ids.each do |sys_id, map_id|
      resp = staff_api.system_settings(sys_id, "space_ref_id").get
      value = resp.as_s?.try(&.to_i64?) || resp.as_i64?
      next unless value
      ids[value] = map_id
    end
    ids
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

  LOCATION = {"desk", "area"}

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    floor_ids = @zone_lookup[zone_id]?
    return [] of Nil unless floor_ids && floor_ids.size > 0
    return [] of Nil if location && !LOCATION.includes?(location)

    loc = LOCATION
    cache = @occupancy_cache
    cache.compact_map do |(room_id, space)|
      next unless space.floor_id.in?(floor_ids)
      people_count = space.occupancy

      if @return_empty_spaces || people_count && people_count > 0
        # TODO:: attach space environment conditions in the future
        # if env = space.environment
        #  humidity = env.humidity.value
        #  temperature = env.temperature.value
        #  iaq = env.iaq.try &.value
        # end
        if space.pir?
          capacity = 1
          loc_type = loc[1]
        else
          loc_type = loc[0]
          capacity = nil
        end

        if map_id = map_ids[space.room_id]?
          capacity = 1
          loc_type = loc[1]
        else
          map_id = "room-#{space.room_id}"
        end

        {
          location:    loc_type,
          at_location: people_count,
          map_id:      map_id,
          level:       zone_id,
          building:    @floor_mappings[space.floor_id.to_s]?.try(&.[](:building_id)),
          capacity:    capacity,

          kontakt_io_room: space.room_name,
        }
      end
    end
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
      return nil if room.pir?
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

    rooms = if room
              {room}
            elsif levels
              @occupancy_cache.values.select do |r|
                floor_id = r.floor_id
                floor_id.in?(levels) || @floor_mappings[floor_id.to_s]?.nil?
              end
            else
              @occupancy_cache.values
            end
    rooms.flat_map { |r| build_sensors(r, sensor_type) }
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
