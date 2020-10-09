module Place; end

require "./area_config"
require "./area_polygon"

class Place::AreaCount < PlaceOS::Driver
  descriptive_name "PlaceOS Area Counter"
  generic_name :Counter
  description %(counts trackable objects in an area, such as people)

  default_settings({
    building: "",

    username: "",
    password: "",
    client_id: "",
    client_secret: "",

    # time in seconds
    poll_rate: 60,

    # Driver to query
    location_service: "LocationServices",

    areas: {
      "zone-1234" => [
        {
          id:       "lobby1",
          name:     "George St Lobby",
          building: "building-zone-id",
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

  # zone_id => areas
  @level_areas : Hash(String, Array(AreaConfig)) = {} of String => Array(AreaConfig)
  # area_id => area
  @areas : Hash(String, AreaConfig) = {} of String => AreaConfig

  # PlaceOS client config
  @building_id : String = ""
  @username : String = ""
  @password : String = ""
  @client_id : String = ""
  @client_secret : String = ""

  @poll_rate : Time::Span = 60.seconds
  @location_service : String = "LocationServices"

  def on_load
    on_update
  end

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds
    @location_service = setting?(String, :location_service).presence || @location_service

    if building = setting?(String, :building).presence
      # We expect the configuration to be stored in the zone metadata
      # we use the Place Client to extract the data
      @building_id = building
      @username = setting(String, :username)
      @password = setting(String, :password)
      @client_id = setting(String, :client_id)
      @client_secret = setting(String, :client_secret)

      # TODO:: grab the zone metadata
    else
      # Zones are defined in settings, this is mainly here so we can write specs
      areas = setting(Hash(String, Array(AreaSetting)), :areas)
      @level_areas.clear
      areas.each do |zone_id, areas|
        @level_areas[zone_id] = areas.map do |area|
          config = AreaConfig.new(area[:id], area[:name], area[:coordinates], area[:building])
          @areas[config.id] = config
          config
        end
      end
    end

    schedule.clear
    schedule.every(@poll_rate) { request_locations }
  end

  protected def location_service
    system[@location_service]
  end

  def request_locations
    @level_areas.each do |level_id, areas|
      begin
        locations = location_service.device_locations(level_id).get.as_a
        self[level_id] = {
          value: locations,
          ts_hint: "complex",
          ts_map: {
            x: "xloc",
            y: "yloc",
          },
          ts_fields: {
            level: level_id,
          },
          ts_tags: {
            building: areas.first.building
          }
        }
        areas.each do |area|

        end
      rescue error
        log_location_parsing(error, level_id)
        sleep 200.milliseconds
      end
    end
  end

  protected def log_location_parsing(error, level_id)
    logger.debug(exception: error) { "while parsing #{level_id}" }
  rescue
  end

  def is_inside?(x : Float64, y : Float64, area_id : String)
    area = @areas[area_id]
    area.polygon.contains(x, y)
  end
end
