require "placeos-driver"
require "./blinds/**"

class Cisco::Blinds::Driver < PlaceOS::Driver
  descriptive_name "Cisco Blinds Controller"
  generic_name :Blinds
  uri_base "https://demo.com/"

  alias Client = Cisco::Blinds::Client

  def on_load
    on_update
  end

  def on_update
    host_name = config.uri.not_nil!.to_s

    @client = Client.new(base_url: host_name)
  end

  def up
    @client.try(&.up)
    self["state"] = "up"
  end

  def down
    @client.try(&.down)
    self["state"] = "down"
  end

  def off
    @client.try(&.off)
    self["state"] = "off"
  end
end
