module Place; end

require "set"
require "placeos"
require "./area_config"
require "./area_polygon"

class Place::AreaManagement < PlaceOS::Driver
  descriptive_name "PlaceOS Area Management"
  generic_name :AreaManagement
  description %(counts trackable objects, such as laptops, in building areas)

  default_settings({
    building: "zone-12345",

    # PlaceOS API creds, so we can query the zone metadata
    placeos_domain: "https://domain.name",
    username:       "",
    password:       "",
    client_id:      "",
    client_secret:  "",

    # time in seconds
    poll_rate: 60,

    # How many wireless devices should we ignore
    duplication_factor: 0.8,

    # Driver to query
    location_service: "LocationServices",

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
  })

  alias AreaSetting = NamedTuple(
    id: String,
    name: String,
    building: String?,
    coordinates: Array(Tuple(Float64, Float64)))

  alias AreaDetails = NamedTuple(
    area_id: String,
    name: String,
    count: Int32,
  )

  alias LevelCapacity = NamedTuple(
    total_desks: Int32,
    total_capacity: Int32,
    desk_ids: Array(String),
  )

  alias RawLevelDetails = NamedTuple(
    wireless_devices: Int32,
    desk_usage: Int32,
    capacity: LevelCapacity,
  )

  # zone_id => areas
  @level_areas : Hash(String, Array(AreaConfig)) = {} of String => Array(AreaConfig)
  # area_id => area
  @areas : Hash(String, AreaConfig) = {} of String => AreaConfig

  # zone_id => desk_ids
  @duplication_factor : Float64 = 0.8
  @level_details : Hash(String, LevelCapacity) = {} of String => LevelCapacity

  # PlaceOS client config
  @building_id : String = ""
  @client : PlaceOS::Client? = nil

  @poll_rate : Time::Span = 60.seconds
  @location_service : String = "LocationServices"

  @rate_limit : Channel(Nil) = Channel(Nil).new
  @update_lock : Mutex = Mutex.new
  @terminated = false

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

    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds
    @location_service = setting?(String, :location_service).presence || "LocationServices"
    @duplication_factor = setting?(Float64, :duplication_factor) || 0.8

    # We expect the configuration to be stored in the zone metadata
    # we use the Place Client to extract the data
    username = setting(String, :username)
    password = setting(String, :password)
    client_id = setting(String, :client_id)
    client_secret = setting(String, :client_secret)
    placeos_domain = setting(String, :placeos_domain)
    @client = PlaceOS::Client.new(placeos_domain,
      email: username,
      password: password,
      client_id: client_id,
      client_secret: client_secret
    )

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
  end

  # The location services provider
  protected def location_service
    system[@location_service]
  end

  # Updates a single zone, syncing the metadata
  protected def update_level_details(level_details, zone, metadata)
    return unless zone.tags.includes?("level")

    if desks = metadata["desks"]?
      ids = desks.details.as_a.map { |desk| desk["id"].as_s }
      level_details[zone.id] = {
        total_desks:    ids.size,
        total_capacity: zone.capacity,
        desk_ids:       ids,
      }
    else
      level_details[zone.id] = {
        total_desks:    zone.count,
        total_capacity: zone.capacity,
        desk_ids:       [] of String,
      }
    end

    if regions = metadata["map_regions"]?
      area_data = Array(AreaConfig).from_json(regions.details["areas"].to_json)
      @level_areas[zone.id] = area_data
      area_data.each { |area| @areas[area.id] = area }
    else
      @level_areas.delete(zone.id)
    end
  end

  # Grabs all the level zones in the building and syncs the metadata
  protected def sync_level_details
    # Attempt to obtain the latest version of the metadata
    response = client.metadata.children(@building_id)

    level_details = {} of String => LevelCapacity
    response.each do |meta|
      update_level_details(level_details, meta[:zone], meta[:metadata])
    end
    @level_details = level_details
  rescue error
    logger.error(exception: error) { "obtaining level metadata" }
  end

  protected def update_level_locations(level_counts, level_id, details)
    areas = @level_areas[level_id]? || [] of AreaConfig

    # Provide the frontend with the list of all known desk ids on a level
    self["#{level_id}:desk_ids"] = details[:desk_ids]

    # Get location data for the level
    locations = location_service.device_locations(level_id).get.as_a

    # Provide to the frontend
    self[level_id] = {
      value:   locations,
      ts_hint: "complex",
      ts_map:  {
        x: "xloc",
        y: "yloc",
      },
      ts_tag_keys: {"s2_cell_id"},
      ts_fields:   {
        pos_level: level_id,
      },
      ts_tags: {
        pos_building: @building_id,
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
        desk_count += 1
        false
      else
        false
      end
    end

    # build the level overview
    level_counts[level_id] = {
      wireless_devices: wireless_count,
      desk_usage:       desk_count,
      capacity:         details,
    }

    # we need to know the map dimensions to be able to count people in areas
    map_width = -1.0
    map_height = -1.0

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
    area_counts = [] of AreaDetails
    if map_width && map_height
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

        area_counts << {
          area_id: area.id,
          name:    area.name,
          count:   count,
        }
      end
    end

    # Provide the frontend the area details
    self["#{level_id}:areas"] = {
      value:     area_counts,
      ts_hint:   "complex",
      ts_fields: {
        pos_level: level_id,
      },
      ts_tags: {
        pos_building: @building_id,
      },
    }
  rescue error
    log_location_parsing(error, level_id)
    sleep 200.milliseconds
  end

  @level_counts : Hash(String, RawLevelDetails) = {} of String => RawLevelDetails

  def request_locations
    @update_lock.synchronize do
      sync_level_details

      # level => user count
      level_counts = {} of String => RawLevelDetails
      @level_details.each do |level_id, details|
        update_level_locations(level_counts, level_id, details)
      end
      @level_counts = level_counts
      update_overview
    end
  end

  def request_level_locations(level_id : String) : Nil
    @update_lock.synchronize do
      zone = client.zones.fetch(level_id)
      if !zone.tags.includes?("level")
        logger.warn { "attempted to update location for #{zone.name} (#{level_id}) which is not tagged as a level" }
        return
      end
      metadata = client.metadata.fetch(level_id)

      update_level_details @level_details, zone, metadata
      update_level_locations @level_counts, level_id, @level_details[level_id]
      update_overview
    end
  end

  protected def update_overview
    self[:overview] = @level_counts.transform_values { |details| build_level_stats(**details) }
  end

  protected def log_location_parsing(error, level_id)
    logger.debug(exception: error) { "while parsing #{level_id}" }
  rescue
  end

  def is_inside?(x : Float64, y : Float64, area_id : String)
    area = @areas[area_id]
    area.polygon.contains(x, y)
  end

  protected def build_level_stats(wireless_devices, desk_usage, capacity)
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
      desk_count:       total_desks,
      desk_usage:       desk_usage,
      device_capacity:  total_capacity,
      device_count:     wireless_devices,
      estimated_people: adjusted_devices.to_i,
      percentage_use:   percentage_use,

      # higher the number, better the recommendation
      recommendation: recommendation,
    }
  end

  protected def client
    @client.not_nil!
  end

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
          if @update_all
            request_locations
          else
            @update_levels.each { |level_id| request_level_locations level_id }
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
