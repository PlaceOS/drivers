require "placeos-driver"
require "./mist_models"

# docs: https://aca.im/driver_docs/Juniper/mist_site_api.pdf

class Juniper::MistWebsocket < PlaceOS::Driver
  generic_name :MistWebsocket
  descriptive_name "Juniper Mist Websocket"
  description "Juniper Mist location data using websockets"

  uri_base "wss://api-ws.mist.com/api-ws/v1/stream"
  default_settings({
    api_token:        "token",
    site_id:          "site_id",
    ignore_usernames: ["host/"],
  })

  @api_token : String = ""
  @site_id : String = ""
  @connected : Bool = false

  @storage_lock : Mutex = Mutex.new
  @user_mac_mappings : PlaceOS::Driver::RedisStorage? = nil
  @ignore_usernames : Array(String) = [] of String

  protected def user_mac_mappings
    @storage_lock.synchronize {
      yield @user_mac_mappings.not_nil!
    }
  end

  getter location_data : Hash(String, Hash(String, Client)) do
    Hash(String, Hash(String, Client)).new { |hash, map_id| hash[map_id] = {} of String => Client }
  end

  getter client_data : Hash(String, Client) { {} of String => Client }

  def on_load
    # We want to store our user => mac_address mappings in redis
    @user_mac_mappings = PlaceOS::Driver::RedisStorage.new(module_id, "user_macs")

    # debug HTTP requests
    transport.http_uri_override = URI.parse("https://api.mist.com")
    transport.before_request do |request|
      logger.debug { "using proxy #{!!transport.proxy_in_use} #{transport.proxy_in_use.inspect}\nconnecting to host: #{config.uri}\nperforming request: #{request.method} #{request.path}\nheaders: #{request.headers}\n#{!request.body.nil? ? String.new(request.body.as(IO::Memory).to_slice) : nil}" }
    end

    on_update
  end

  def on_update
    token = setting String, :api_token
    @api_token = "Token #{token}"
    @site_id = setting String, :site_id
    @ignore_usernames = setting?(Array(String), :ignore_usernames) || [] of String

    connected if @connected
  end

  def websocket_headers
    HTTP::Headers{
      "Authorization" => @api_token,
      "User-Agent"    => "PlaceOS/2.0 PlaceTechnology",
    }
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

  protected def update_location(client_data, location_data, client) : Nil
    if old_details = client_data[client.mac]?
      if old_details.map_id != client.map_id
        location_data[old_details.map_id].delete(old_details.mac)
      end
    end

    client_mac = format_mac client.mac
    location_data[client.map_id][client_mac] = client
    client_data[client_mac] = client

    self[client_mac] = client
    if username = client.username
      user_mac_mappings { |storage| map_user_mac(client_mac, username, storage) }
    end
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

  def site_list(org_id : String)
    request(Array(Hash(String, JSON::Any))) { |headers| get("/api/v1/installer/orgs/#{org_id}/sites", headers: headers) }
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

  def format_username(user : String)
    if user.includes? "@"
      user = user.split("@")[0]
    elsif user.includes? "\\"
      user = user.split("\\")[1]
    end
    user.downcase
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def macs_assigned_to(username : String) : Array(String)
    username = format_username(username)
    if macs = user_mac_mappings { |s| s[username]? }
      Array(String).from_json(macs)
    else
      [] of String
    end
  end

  def ownership_of(mac_address : String)
    mac_address = format_mac(mac_address)
    user_mac_mappings { |storage| storage[mac_address]? }
  end

  def locate(username : String)
    macs_assigned_to(username).compact_map { |mac| self[mac]? }
  end

  protected def map_user_mac(user_mac, user_id, storage)
    updated_dev = false
    new_devices = false
    user_id = format_username(user_id)

    # Check if mac mapping already exists
    existing_user = storage[user_mac]?
    return {false, false} if existing_user == user_id

    # Remove any pervious mappings
    if existing_user
      updated_dev = true
      if user_macs = storage[existing_user]?
        macs = Array(String).from_json(user_macs)
        macs.delete(user_mac)
        storage[existing_user] = macs.to_json
      end
    else
      new_devices = true
    end

    # Update the user mappings
    storage[user_mac] = user_id
    macs = if user_macs = storage[user_id]?
             tmp_macs = Array(String).from_json(user_macs)
             tmp_macs.unshift(user_mac)
             tmp_macs.uniq!
             tmp_macs[0...9]
           else
             [user_mac]
           end
    storage[user_id] = macs.to_json

    {updated_dev, new_devices}
  end

  @[Security(PlaceOS::Driver::Level::Administrator)]
  def mac_address_mappings(username : String, macs : Array(String), domain : String = "")
    username = format_username(username)
    user_mac_mappings do |storage|
      macs.each { |mac| map_user_mac(format_mac(mac), username, storage) }
    end
  end
end
