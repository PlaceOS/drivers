require "set"
require "placeos"
require "placeos-driver"
require "./area_config"
require "./area_polygon"
require "placeos-driver/interface/sensor"

class Place::AreaManagement < PlaceOS::Driver
  descriptive_name "PlaceOS Area Management"
  generic_name :AreaManagement
  description %(counts trackable objects, such as laptops, in building areas)

  accessor staff_api : StaffAPI_1

  default_settings({
    building: "zone-12345",

    # time in seconds
    poll_rate: 60,

    # How many decimal places area summaries should be rounded to
    rounding_precision: 2,

    # How many wireless devices should we ignore
    duplication_factor: 0.8,

    # Driver to query
    location_service: "LocationServices",
    include_sensors:  true,

    areas: {
      "zone-1234" => [
        {
          id:          "lobby1",
          name:        "George St Lobby",
          building:    "building-zone-id",
          coordinates: [{3, 5}, {5, 6}, {6, 1}],
        },
      ],
    },

    # If another systems has different desk IDs configured you can add them to
    # desk metadata and then specify the alternative field names here
    # desk_id_mappings: ["floorsensedeskid", "vergesensedeskid"]
  })

  alias AreaSetting = NamedTuple(
    id: String,
    name: String,
    building: String?,
    coordinates: Array(Tuple(Float64, Float64)))

  alias LevelCapacity = NamedTuple(
    total_desks: Int32,
    total_capacity: Int32,
    desk_ids: Array(String),
    desk_mappings: Hash(String, String))

  alias RawLevelDetails = NamedTuple(
    wireless_devices: Int32,
    desk_usage: Int32,
    capacity: LevelCapacity,
    sensors: Hash(String, Float64),
  )

  # zone_id => sensors
  @level_sensors : Hash(String, Hash(String, SensorMeta)) = {} of String => Hash(String, SensorMeta)
  # zone_id => areas
  @level_areas : Hash(String, Array(AreaConfig)) = {} of String => Array(AreaConfig)
  # area_id => area
  @areas : Hash(String, AreaConfig) = {} of String => AreaConfig

  # zone_id => desk_ids
  @duplication_factor : Float64 = 0.8
  @level_details : Hash(String, LevelCapacity) = {} of String => LevelCapacity

  # PlaceOS client config
  @building_id : String = ""

  @poll_rate : Time::Span = 60.seconds
  @location_service : String = "LocationServices"

  @rate_limit : Channel(Nil) = Channel(Nil).new
  @update_lock : Mutex = Mutex.new
  @terminated : Bool = false
  @include_sensors : Bool = false
  @sensor_discovery = {} of String => SensorMeta

  @desk_id_mappings = [] of String

  @rounding_precision : UInt32 = 2

  def on_load
    spawn { rate_limiter }
    spawn(same_thread: true) { update_scheduler }

    on_update
  end

  def on_unload
    @terminated = true
    @rate_limit.close
  end

  def on_update
    @building_id = setting(String, :building)
    @include_sensors = setting?(Bool, :include_sensors) || false
    @desk_id_mappings = setting?(Array(String), :desk_id_mappings) || [] of String

    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds
    @location_service = setting?(String, :location_service).presence || "LocationServices"
    @duplication_factor = setting?(Float64, :duplication_factor) || 0.8
    @sensor_discovery = {} of String => SensorMeta

    @rounding_precision = setting?(UInt32, :rounding_precision) || 2_u32

    # Areas are defined in metadata, this is mainly here so we can write specs
    if building_areas = setting?(Hash(String, Array(AreaSetting)), :areas)
      @level_areas.clear
      building_areas.each do |zone_id, areas|
        @level_areas[zone_id] = areas.map do |area|
          config = AreaConfig.new(area[:id], area[:name], area[:coordinates], area[:building])
          @areas[config.id] = config
          config
        end
      end
    end

    schedule.clear
    schedule.every(@poll_rate) { synchronize_all_levels }

    if @include_sensors
      schedule.in(@poll_rate * 3) do
        # sync the sensor discovery data for map placement
        schedule.every(2.hours + rand(300).seconds, immediate: true) { write_sensor_discovery }
      end
    end
  end

  # The location services provider
  protected def location_service
    system[@location_service]
  end

  # ===============================
  # SENSOR DETAILS
  # ===============================

  alias SensorDetail = Interface::Sensor::Detail
  alias SensorType = Interface::Sensor::SensorType

  struct SensorMeta
    include JSON::Serializable

    def initialize(@name, @type, @level, @x, @y)
    end

    property type : SensorType?
    property name : String?
    property level : String?
    property x : Float64?
    property y : Float64?
  end

  def write_sensor_discovery
    staff_api.write_metadata(@building_id, "sensor-discovered", @sensor_discovery)
  end

  # returns the sensor location data that has been configured
  def sensor_locations(level_id : String? = nil)
    if level_id
      @level_sensors[level_id]? || {} of String => SensorMeta
    else
      @level_sensors.values.reduce({} of String => SensorMeta) { |acc, i| acc.merge!(i) }
    end
  end

  # Queries all the sensors in a building and exposes the data
  def request_sensor_data(level_id : String? = nil) : Hash(String, Array(SensorDetail))
    sensors = if level_id
                location_service.sensors(zone_id: level_id).get.as_a
              else
                location_service.sensors.get.as_a
              end

    levels = Hash(String, Array(SensorDetail)).new { |h, k| h[k] = [] of SensorDetail }

    return levels if sensors.empty?
    details = Array(SensorDetail).from_json(sensors.to_json)

    building_id = @building_id
    locs = sensor_locations(level_id)

    details.each do |sensor|
      id = sensor.id ? "#{sensor.mac}-#{sensor.id}" : sensor.mac
      @sensor_discovery[id] = SensorMeta.new(
        sensor.name,
        sensor.type,
        sensor.level,

        # TODO:: calculate x, y if a loc is given
        sensor.x,
        sensor.y
      )

      sensor.module_id = sensor.binding = sensor.loc = nil

      # check if this sensor has a user defined location
      if location = locs[id]?
        sensor.x = location.x
        sensor.y = location.y
        sensor.level = location.level
        sensor.building = building_id
      end

      if sensor.x && (level_id ? sensor.level == level_id : sensor.level)
        # TODO:: calulate the lat, lon and s2 cell id

        levels[sensor.level] << sensor
      end
    end

    levels.each do |level, the_sensors|
      self["#{level}:sensors"] = {
        value:   the_sensors,
        ts_hint: "complex",
        ts_map:  {
          x: "xloc",
          y: "yloc",
        },
        ts_tag_keys: {"s2_cell_id"},
        ts_tags:     {
          pos_building: building_id,
          pos_level:    level,
        },
      }
    end

    levels
  end

  # ===============================
  # LOCATION DETAILS
  # ===============================

  # Updates a single zone, syncing the metadata
  protected def update_level_details(level_details, zone, metadata)
    return unless zone.tags.includes?("level")

    if desks = metadata["desks"]?
      desk_map = {} of String => String

      if @desk_id_mappings.empty?
        ids = desks.details.as_a.map { |desk| desk["id"].as_s }
      else
        desk_details = desks.details.as_a
        ids = Array(String).new(desk_details.size)

        desk_details.each do |desk|
          desk_id = desk["id"].as_s
          ids << desk_id
          @desk_id_mappings.each do |mapping|
            if alt_id = desk[mapping]?
              desk_map[alt_id.as_s] = desk_id
            end
          end
        end
      end

      ids = desks.details.as_a.map { |desk| desk["id"].as_s }
      level_details[zone.id] = {
        total_desks:    ids.size,
        total_capacity: zone.capacity,
        desk_ids:       ids,
        desk_mappings:  desk_map,
      }
    else
      level_details[zone.id] = {
        total_desks:    zone.count,
        total_capacity: zone.capacity,
        desk_ids:       [] of String,
        desk_mappings:  {} of String => String,
      }
    end

    if regions = metadata["map_regions"]?
      area_data = Array(AreaConfig).from_json(regions.details["areas"].to_json)
      @level_areas[zone.id] = area_data
      area_data.each { |area| @areas[area.id] = area }
    else
      @level_areas.delete(zone.id)
    end

    if sensors = metadata["sensor-locations"]?
      sensor_data = Hash(String, SensorMeta).from_json(sensors.details.to_json)
      zone_id = zone.id
      sensor_data.transform_values! { |sensor| sensor.level = zone_id; sensor }
      @level_sensors[zone_id] = sensor_data
    else
      @level_sensors.delete(zone.id)
    end
  end

  alias Zone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, PlaceOS::Client::API::Models::Metadata)
  alias ChildMetadata = Array(NamedTuple(zone: Zone, metadata: Metadata))

  # Grabs all the level zones in the building and syncs the metadata
  protected def sync_level_details
    # Attempt to obtain the latest version of the metadata
    response = ChildMetadata.from_json(staff_api.metadata_children(@building_id).get.to_json)

    level_details = {} of String => LevelCapacity
    response.each do |meta|
      update_level_details(level_details, meta[:zone], meta[:metadata])
    end
    @level_details = level_details
  rescue error
    logger.error(exception: error) { "obtaining level metadata" }
  end

  protected def update_level_locations(level_counts, level_id, details, sensor_data)
    areas = @level_areas[level_id]? || [] of AreaConfig
    unsorted_sensors = sensor_data.try &.[]?(level_id) || [] of SensorDetail
    sensors = Hash(SensorType, Array(SensorDetail)).new { |h, k| h[k] = [] of SensorDetail }
    unsorted_sensors.each { |sensor| sensors[sensor.type] << sensor }

    # Provide the frontend with the list of all known desk ids on a level
    self["#{level_id}:desk_ids"] = details[:desk_ids]

    # Get location data for the level
    locations = location_service.device_locations(level_id).get.as_a

    # Apply any map id transformations
    desk_mappings = details[:desk_mappings]
    locations = locations.map do |loc|
      loc = loc.as_h
      if location_type = loc["location"]?
        # measurement name for simplified querying in influxdb
        loc["measurement"] = location_type
        if location_type == "desk"
          if maps_to = desk_mappings[loc["map_id"].as_s]?
            loc["map_id"] = JSON::Any.new(maps_to)
          end
        end
      end
      loc
    end

    # Provide to the frontend
    self[level_id] = {
      value:   locations,
      ts_hint: "complex",
      ts_map:  {
        x: "xloc",
        y: "yloc",
      },
      ts_tag_keys: {"s2_cell_id"},
      ts_tags:     {
        pos_building: @building_id,
        pos_level:    level_id,
      },
    }

    # Grab the x,y locations
    wireless_count = 0
    desk_count = 0
    xy_locs = locations.select do |loc|
      case loc["location"].as_s
      when "wireless"
        wireless_count += 1

        # Keep if x, y coords are present
        !loc["x"].raw.nil?
      when "desk"
        desk_count += 1 if (loc["at_location"]?.try(&.as_i?) || 0) > 0
        false
      else
        false
      end
    end

    people_counts = sensors[SensorType::PeopleCount]?
    sensor_summary = sensors.transform_keys(&.to_s.underscore).transform_values do |values|
      if values.size > 0
        (values.sum(&.value) / values.size).round(@rounding_precision)
      else
        0.0
      end
    end
    if people_counts
      sensor_summary["people_count_sum"] = people_counts.sum(&.value)
    end

    # build the level overview
    level_counts[level_id] = {
      wireless_devices: wireless_count,
      desk_usage:       desk_count,
      capacity:         details,
      sensors:          sensor_summary,
    }

    # we need to know the map dimensions to be able to count people in areas
    map_width = 100.0
    map_height = 100.0

    if tmp_loc = xy_locs[0]?
      # ensure map width and height are known
      map_width_raw = tmp_loc["map_width"]?.try(&.raw)
      case map_width_raw
      when Int64, Float64
        map_width = map_width_raw.to_f
      end

      map_height_raw = tmp_loc["map_height"]?.try(&.raw)
      case map_height_raw
      when Int64, Float64
        map_height = map_height_raw.to_f
      end
    end

    # Calculate the device counts for each area
    area_counts = [] of Hash(String, String | Int32 | Float64)
    if map_width != -1.0
      # adjust sensor x,y so we check if they are in areas
      sensors.each do |_type, array|
        array.map! do |sensor|
          sensor.x = sensor.x.not_nil! * map_width
          sensor.y = sensor.y.not_nil! * map_height
          sensor
        end
      end

      areas.each do |area|
        count = 0

        # Ensure the area is configured
        area.coordinates(map_width, map_height)
        polygon = area.polygon

        # Calculate counts, our config uses browser coordinate systems,
        # so need to adjust any x,y values being received for this
        xy_locs.each do |loc|
          case loc["coordinates_from"]?.try(&.raw)
          when "bottom-left"
            count += 1 if polygon.contains(loc["x"].as_f, map_height - loc["y"].as_f)
          else
            count += 1 if polygon.contains(loc["x"].as_f, loc["y"].as_f)
          end
        end

        # build sensor summary for the area
        area_sensors = Hash(SensorType, Array(SensorDetail)).new { |h, k| h[k] = [] of SensorDetail }
        sensors.each do |type, array|
          array.each do |sensor|
            area_sensors[type] << sensor if polygon.contains(sensor.x.not_nil!, sensor.y.not_nil!)
          end
        end

        people_counts = area_sensors[SensorType::PeopleCount]?
        sensor_summary = area_sensors.transform_keys(&.to_s.underscore).transform_values do |values|
          if values.size > 0
            (values.sum(&.value) / values.size).round(@rounding_precision)
          else
            0.0
          end
        end
        if people_counts
          sensor_summary["people_count_sum"] = people_counts.sum(&.value)
        end

        area_counts << {
          "area_id" => area.id,
          "name"    => area.name,
          "count"   => (count * @duplication_factor).to_i,
        }.merge(sensor_summary)
      end
    end

    # Provide the frontend the area details
    self["#{level_id}:areas"] = {
      value:       area_counts,
      measurement: "area_summary",
      ts_hint:     "complex",
      ts_tags:     {
        pos_building: @building_id,
        pos_level:    level_id,
      },
    }
  rescue error
    logger.debug(exception: error) { "while parsing #{level_id}" }
    sleep 200.milliseconds
  end

  @level_counts : Hash(String, RawLevelDetails) = {} of String => RawLevelDetails

  def request_locations(sensor_data : Hash(String, Array(SensorDetail))? = nil)
    @update_lock.synchronize do
      # level => user count
      level_counts = {} of String => RawLevelDetails
      @level_details.each do |level_id, details|
        update_level_locations(level_counts, level_id, details, sensor_data)
      end
      @level_counts = level_counts
      update_overview
    end
  end

  def request_level_locations(level_id : String, sensor_data : Hash(String, Array(SensorDetail))? = nil) : Nil
    @update_lock.synchronize do
      zone = Zone.from_json(staff_api.zone(level_id).get.to_json)
      if !zone.tags.includes?("level")
        logger.warn { "attempted to update location for #{zone.name} (#{level_id}) which is not tagged as a level" }
        return
      end
      metadata = Metadata.from_json(staff_api.metadata(level_id).get.to_json)

      update_level_details @level_details, zone, metadata
      update_level_locations @level_counts, level_id, @level_details[level_id], sensor_data
      update_overview
    end
  end

  protected def update_overview
    self[:overview] = @level_counts.transform_values { |details| build_level_stats(**details) }
  end

  def is_inside?(x : Float64, y : Float64, area_id : String)
    area = @areas[area_id]
    area.polygon.contains(x, y)
  end

  protected def build_level_stats(wireless_devices, desk_usage, capacity, sensors)
    # raw data
    total_desks = capacity[:total_desks]
    total_capacity = capacity[:total_capacity]

    # normalised data
    adjusted_devices = wireless_devices * @duplication_factor

    if total_capacity <= 0
      percentage_use = 100.0
      individual_impact = 100.0
    else
      percentage_use = (adjusted_devices / total_capacity) * 100.0
      individual_impact = 100.0 / total_capacity
    end
    remaining_capacity = total_capacity - adjusted_devices
    recommendation = remaining_capacity + remaining_capacity * individual_impact

    {
      "measurement"      => "level_summary",
      "desk_count"       => total_desks,
      "desk_usage"       => desk_usage,
      "device_capacity"  => total_capacity,
      "device_count"     => wireless_devices,
      "estimated_people" => adjusted_devices.to_i,
      "percentage_use"   => percentage_use,

      # higher the number, better the recommendation
      "recommendation" => recommendation,
    }.merge(sensors)
  end

  # ===============================
  # RATE LIMITER
  # ===============================

  # This is to limit the number of "real-time" updates
  # batching operations to provide fast updates that don't waste CPU cycles
  protected def rate_limiter
    sleep 3

    loop do
      begin
        break if @rate_limit.closed?
        @rate_limit.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep 3
      end
    end
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter } unless @terminated
  end

  @update_levels : Set(String) = Set.new([] of String)
  @update_all : Bool = true
  @schedule_lock : Mutex = Mutex.new

  def update_available(level_ids : Array(String))
    @schedule_lock.synchronize { @update_levels.concat level_ids }
  end

  def synchronize_all_levels
    @schedule_lock.synchronize { @update_all = true }
  end

  protected def update_scheduler
    loop do
      @rate_limit.receive
      @schedule_lock.synchronize do
        begin
          sensor_data = {} of String => Array(SensorDetail)
          if @update_all
            @update_lock.synchronize { sync_level_details }
            sensor_data = request_sensor_data if @include_sensors
            request_locations sensor_data
          else
            @update_levels.each do |level_id|
              sensor_data = request_sensor_data(level_id) if @include_sensors
              request_level_locations level_id, sensor_data
            end
          end
        rescue error
          logger.error(exception: error) { "error updating floors" }
        ensure
          @update_levels.clear
          @update_all = false
        end
      end
    end
  end
end
