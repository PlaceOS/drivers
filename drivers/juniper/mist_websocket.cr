require "placeos-driver"
require "./mist_models"

class Juniper::MistWebsocket < PlaceOS::Driver
  generic_name :MistWebsocket
  descriptive_name "Juniper Mist Websocket"
  description "Juniper Mist location data using websockets"

  uri_base "wss://api.mist.com/api-ws/v1/stream"
  default_settings({
    api_token: "token",
    site_id:   "site_id",
  })

  @api_token : String = ""
  @site_id : String = ""
  @connected : Bool = false

  getter location_data : Hash(String, Hash(String, Client)) do
    Hash(String, Hash(String, Client)).new { |hash, map_id| hash[map_id] = {} of String => Client }
  end

  getter client_data : Hash(String, Client) { {} of String => Client }

  def on_load
    on_update
  end

  def on_update
    token = setting String, :api_token
    @api_token = "Token #{token}"
    @site_id = setting String, :site_id

    connected if @connected
  end

  def connected
    @connected = true
    @location_data = nil
    @client_data = nil

    # We'll use this as the keepalive message
    schedule.every(45.seconds, immediate: true) do
      transport.send({subscribe: "/sites/#{@site_id}/stats/clients"}.to_json)
    end
    sync_clients
    schedule.every(3.seconds) { update_client_locations }
  end

  def disconnected
    schedule.clear
    @connected = false
  end

  protected def request(klass : Class)
    headers = HTTP::Headers{
      "Authorization" => @api_token,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
      "User-Agent"    => "PlaceOS/2.0 PlaceTechnology",
    }

    response = yield headers

    raise "request failed with status: #{response.status_code}\n#{response.body}" unless response.success?
    klass.from_json(response.body)
  end

  protected def update_location(client_data, location_data, client)
    if old_details = client_data[client.mac]?
      if old_details.map_id != client.map_id
        location_data[old_details.map_id].delete(old_details.mac)
      end
    end

    location_data[client.map_id][client.mac] = client
    client_data[client.mac] = client
  end

  def sync_clients
    clients_resp = clients
    loc_data = location_data
    cli_data = client_data

    # build the internal representation
    clients_resp.each { |client| update_location(cli_data, loc_data, client) }

    # expose this to the world
    loc_data.each { |map_id, clients| self[map_id] = clients.values }
    location_data.size
  end

  # batch update redis (don't want lots of websocket events to overload other services)
  protected def update_client_locations
    location_data.each { |map_id, clients| self[map_id] = clients.values }
  end

  @[Security(Level::Support)]
  def get_request(location : String)
    request(JSON::Any) { |headers| get(location, headers: headers) }
  end

  def maps
    request(Array(Map)) { |headers| get("/api/v1/sites/#{@site_id}/maps", headers: headers) }
  end

  def clients(map_id : String? = nil)
    if map_id.presence
      request(Array(Client)) { |headers| get("/api/v1/sites/#{@site_id}/stats/maps/#{map_id}/clients", headers: headers) }
    else
      request(Array(Client)) { |headers| get("/api/v1/sites/#{@site_id}/stats/clients", headers: headers) }
    end
  end

  def client(client_mac : String)
    request(Client) { |headers| get("/api/v1/sites/#{@site_id}/stats/clients/#{client_mac}", headers: headers) }
  end

  struct WebsocketEvent
    include JSON::Serializable

    getter event : String
    getter channel : String
    getter data : Client
  end

  def received(data, task)
    string = String.new(data).rstrip
    logger.debug { "websocket sent: #{string}" }
    event = WebsocketEvent.from_json(string)

    update_location(client_data, location_data, event.data)

    task.try &.success
  end
end
