require "placeos-driver"
require "quantum"

class Lutron::Quantum < PlaceOS::Driver
  descriptive_name "Lutron Quantum Gateway"
  generic_name :Lighting
  uri_base "https://engineeringwebdemo01.lutron.com/"

  alias Client = ::Quantum::Client

  default_settings({
    api_key:    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    device_key: "ab22c585-14e6-4c6b-b418-166728bcc608",
  })

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    host_name = URI.parse(config.uri.not_nil!).host
    api_key = setting(String, :api_key)
    device_key = setting(String, :device_key)

    @client = Client.new(host_name: host_name.not_nil!, api_key: api_key, device_key: device_key)
  end

  def level?(zone_id : Int32)
    status = client.zone.get_status(zone_id)
    self["area#{zone_id}_level"] = status["Level"]
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def level(zone_id : Int32, level : String)
    client.zone.set_status_level(id: zone_id, level: level)
    self["zone#{zone_id}_level"] = level
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def scene(area_id : Int32, scene : Int32)
    client.area.set_scene(id: area_id, scene: scene)
    self["area#{area_id}"] = scene
  end

  def scene?(area_id : Int32)
    status = client.area.get_status(area_id: area_id)
    self["area#{area_id}"] = status["CurrentScene"]
  end

  def scenes?(area_id : Int32)
    client.area.get_scenes(id: area_id)
  end

  def area?(area_id : Int32)
    client.area.get_by_id(id: area_id)
  end

  def zones?(area_id : Int32)
    client.area.get_zones(id: area_id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def root
    client.area.root
  end
end
