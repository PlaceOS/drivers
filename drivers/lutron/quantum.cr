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

  def request(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body }

    {HTTP::Status::OK.to_i, {} of String => String, ""}
  rescue error
    logger.warn(exception: error) { "processing webhook request" }
    {HTTP::Status::INTERNAL_SERVER_ERROR.to_i, {"Content-Type" => "application/json"}, error.message.to_s}
  end

  def level?(id : Int32)
    status = client.zone.get_status(id)
    self["area#{id}_level"] = status["Level"]
  end

  def level(id : Int32, level : String)
    client.zone.set_status_level(id: id, level: level)
    self["area#{id}_level"] = level
  end

  def scene(id : Int32, scene : Int32)
    client.area.set_scene(id: id, scene: scene)
    self["area#{id}"] = scene
  end

  def scene?(id : Int32)
    status = client.area.get_status(id: id)
    self["area#{id}"] = status["CurrentScene"]
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def scenes(id : Int32)
    client.area.get_scenes(id: id)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def root
    client.area.root
  end
end
