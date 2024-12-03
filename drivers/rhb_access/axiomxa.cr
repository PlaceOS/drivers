require "placeos-driver"
require "axio"

class RHBAccess::Axiomxa < PlaceOS::Driver
  descriptive_name "RHB Access AxiomXA"
  generic_name :AxiomXa
  uri_base "http://127.0.0.1:60001"

  alias Client = Axio::Client

  default_settings({
    username: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    password: "ABCDEF123456",
  })

  protected getter! client : Client

  def on_update
    host_name = config.uri.not_nil!.to_s
    @client = Client.new(base_url: host_name.to_s, username: setting(String, :username), password: setting(String, :password))
  end

  def lock(id : String, permanent : Bool = false)
    @client.try(&.access_points.lock(id: id, permanent: permanent.to_s))
    self["access_point_#{id}"] = {"Status" => "locked", "permanent" => permanent.to_s}
  end

  def unlock(id : String, permanent : Bool = false)
    @client.try(&.access_points.unlock(id: id, permanent: permanent.to_s))
    self["access_point_#{id}"] = {"Status" => "unlocked", "permanent" => permanent.to_s}
  end

  def status?(id : String)
    response = @client.try(&.access_points.status(id: id))
    self["access_point_#{id}_status"] = JSON.parse(response.not_nil!.body)
  end
end
