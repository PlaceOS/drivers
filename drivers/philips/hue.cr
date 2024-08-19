require "placeos-driver"
require "placeos-driver/interface/lighting"

# documentation: https://developers.meethue.com/develop/hue-api-v2/api-reference/

class Philips::Hue < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level

  # component == resource
  # id == id
  alias Area = Interface::Lighting::Area

  # Discovery Information
  generic_name :Hue
  descriptive_name "Philips Hue Lighting"
  uri_base "https://192.168.4.31"

  default_settings({
    app_key:    "",
    client_key: "",

    scenes: [""],
  })

  def on_load
    on_update
  end

  def on_update
    @app_key = setting(String, :app_key)
    @client_key = setting(String, :client_key)
    @scenes = setting?(Array(String), :scenes) || [] of String
  end

  @[Security(Level::Administrator)]
  getter app_key : String = ""

  @[Security(Level::Administrator)]
  getter client_key : String = ""

  getter scenes : Array(String) = [] of String

  record HueError, type : Int32, address : String, description : String do
    include JSON::Serializable
  end

  record RegSuccess, username : String, clientkey : String do
    include JSON::Serializable
  end

  record RegResponse, success : RegSuccess?, error : HueError? do
    include JSON::Serializable
  end

  def register
    response = post("/api", body: {
      devicetype:        "placeos##{module_id}",
      generateclientkey: true,
    }.to_json)

    raise "unknown error: #{response.body}" unless response.success?

    resp = Array(RegResponse).from_json(response.body)[0]
    if success = resp.success
      @app_key = success.username
      @client_key = success.clientkey
      define_setting(:app_key, @app_key)
      define_setting(:client_key, @client_key)
      @app_key
    else
      error = resp.error.as(HueError)
      logger.error { "type #{error.type}: #{error.description}" }
      error.description
    end
  end

  enum Resource
    Light
    Scene
    Room
    Zone
    GroupedLight
    Device
    Motion
    GroupedMotion
    GroupedLightLevel
    CameraMotion
    Temperature
  end

  def resource_details(resource : Resource, id : String? = nil)
    response = get("/clip/v2/resource/#{resource.to_s.underscore}/#{id}", headers: HTTP::Headers{
      "hue-application-key" => app_key,
    })
    JSON.parse response.body
  end

  def device_list
    resource_details(Resource::Device)
  end

  # convert RGB to CIE which is used by Hue
  def rgb_to_cie(r : UInt8, g : UInt8, b : UInt8) : Tuple(Float64, Float64)
    # Normalize RGB values
    r_norm = r / 255.0
    g_norm = g / 255.0
    b_norm = b / 255.0

    # Apply gamma correction
    r_lin = (r_norm > 0.04045) ? ((r_norm + 0.055) / 1.055) ** 2.4 : r_norm / 12.92
    g_lin = (g_norm > 0.04045) ? ((g_norm + 0.055) / 1.055) ** 2.4 : g_norm / 12.92
    b_lin = (b_norm > 0.04045) ? ((b_norm + 0.055) / 1.055) ** 2.4 : b_norm / 12.92

    # Convert to XYZ
    x = r_lin * 0.4124 + g_lin * 0.3576 + b_lin * 0.1805
    y = r_lin * 0.2126 + g_lin * 0.7152 + b_lin * 0.0722
    z = r_lin * 0.0193 + g_lin * 0.1192 + b_lin * 0.9505

    # Convert to xy
    xy_x = x / (x + y + z)
    xy_y = y / (x + y + z)

    {xy_x, xy_y}
  end

  def set_light_colour(light_id : Int32, r : UInt8 = 0_u8, g : UInt8 = 0_u8, b : UInt8 = 0_u8)
    x, y = rgb_to_cie(r, g, b)
    response = put("/clip/v2/resource/light/#{light_id}", headers: HTTP::Headers{
      "hue-application-key" => app_key,
    }, body: {color: {xy: {x: x, y: y}}}.to_json)
    raise "error controlling light (#{response.status})\n#{response.body}" unless response.success?
    JSON.parse response.body
  end

  def set_light_level(light_id : String, level : UInt32, resource : Resource = Resource::Light)
    level = level.clamp(0, 100)

    if level == 0
      response = put("/clip/v2/resource/#{resource.to_s.underscore}/#{light_id}", headers: HTTP::Headers{
        "hue-application-key" => app_key,
      }, body: {on: {on: false}}.to_json)
    else
      response = put("/clip/v2/resource/#{resource.to_s.underscore}/#{light_id}", headers: HTTP::Headers{
        "hue-application-key" => app_key,
      }, body: {on: {on: true}, dimming: {brightness: level}}.to_json)
    end

    raise "error controlling light (#{response.status})\n#{response.body}" unless response.success?
    level
  end

  def set_scene(scene_id : String)
    response = put("/clip/v2/resource/scene/#{scene_id}", headers: HTTP::Headers{
      "hue-application-key" => app_key,
    }, body: {recall: {action: :active}}.to_json)
    raise "error activating scene (#{response.status})\n#{response.body}" unless response.success?
    response.body
  end

  # ==================
  # Lighting Interface
  # ==================
  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    scene_id = @scenes[scene]
    set_scene scene_id
  end

  def lighting_scene?(area : Area? = nil)
    raise "not really a thing"
  end

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    level_int = level.round_away.to_u32
    area = area.as(Area)
    area_id = area.id.as(String)
    resource = Resource.parse(area.component || "light")

    # TODO:: fade_time is possible using signaling duration
    set_light_level(area_id, level_int, resource)
  end

  def lighting_level?(area : Area? = nil)
    raise "no area provided" unless area
    area_id = area.id.as(String)
    resource = Resource.parse(area.component || "light")

    json = resource_details(resource, area_id)
    state = json["on"]["on"].as_bool
    state ? json["dimming"]["brightness"].as_i : 0
  end
end
