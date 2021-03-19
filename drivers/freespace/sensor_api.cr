module Freespace; end

require "placeos-driver/interface/locatable"
require "uri"
require "stomp"
require "./models"

# https://aca.im/driver_docs/Freespace/Freespace%20Socket%20API-V1.2.pdf

class Freespace::SensorAPI < PlaceOS::Driver
  include Interface::Locatable

  # Discovery Information
  generic_name :Freespace
  descriptive_name "Freespace Websocket API"

  uri_base "https://_instance_.afreespace.com"

  default_settings({
    username: "user",
    password: "pass",

    floor_mappings: {
      "775" => {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
  })

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @floor_mappings = setting(Hash(String, NamedTuple(building_id: String?, level_id: String)), :floor_mappings)

    # configure the zone mappings
    @zone_mappings.clear
    @floor_mappings.each do |location_id, details|
      @zone_mappings[details[:level_id]] << location_id
      @zone_mappings[details[:building_id]] << location_id
    end

    # We want to rebind to everything
    disconnect if @connected
  end

  # We need an API key to connect to the websocket
  def websocket_headers
    HTTP::Headers{
      "X-Auth-Key" => get_token,
    }
  end

  getter! client : STOMP::Client
  @auth_key : String? = nil
  @spaces : Hash(Int64, Space) = {} of Int64 => Space
  @space_state : Hash(Int64, SpaceActivity) = {} of Int64 => SpaceActivity
  @username : String = ""
  @password : String = ""
  @connected : Bool = false

  @floor_mappings : Hash(String, NamedTuple(building_id: String?, level_id: String)) = {} of String => NamedTuple(building_id: String?, level_id: String)
  # Level zone => location_id
  @zone_mappings : Hash(String, Array(String)) = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

  def connected
    @connected = true

    # Send the CONNECT message
    hostname = URI.parse(config.uri.not_nil!).hostname.not_nil!
    @client = STOMP::Client.new(hostname)
    send(client.stomp.to_s)

    schedule.clear
    schedule.in(5.seconds) { @auth_key = nil }
    schedule.every(10.seconds) { heart_beat }
  end

  def disconnected
    @connected = false
    schedule.clear
    @spaces.clear
    @auth_key = @client = nil
  end

  def heart_beat
    send(client.send("/beat/#{Time.utc.to_unix}").to_s, wait: false, priority: 0)
  end

  protected def subscribe_location(location_id) : Nil
    get_location(location_id).each do |space|
      id = space.id
      request = client.subscribe("space-#{id}", "/topic/spaces/#{id}/activities", HTTP::Headers{
        "receipt" => "rec-#{id}",
      })

      # Wait false as the server is not STOMP compliant, it won't respond to receipt headers
      send(request.to_s, wait: false)
    end
  end

  @[Security(Level::Support)]
  def spaces_details
    @spaces
  end

  @[Security(Level::Support)]
  def spaces_state
    @space_state
  end

  @[Security(Level::Support)]
  def get_location(location_id : String | Int64) : Array(Space)
    response = http("POST",
      "/api/locations/#{location_id}/spaces",
      headers: {
        "X-Auth-Key"   => get_token,
        "Content-Type" => "application/json",
        "Accept"       => "application/json",
      }, body: {
      username: @username,
      password: @password,
    }.to_json
    )

    raise "issue obtaining to location #{location_id}: status code #{response.status_code}\n#{response.body}" unless response.success?

    spaces = Array(Space).from_json response.body
    spaces.each { |space| @spaces[space.id] = space }
    spaces
  end

  # Alternative to using basic auth, but here really only for testing with postman
  @[Security(Level::Support)]
  def get_token : String
    auth_key = @auth_key
    return auth_key if auth_key

    response = http("POST",
      "/login",
      headers: {
        "Content-Type" => "application/json",
        "Accept"       => "application/json",
      }, body: {
      username: @username,
      password: @password,
    }.to_json
    )
    logger.debug { "login response: #{response.body}" }
    raise "issue obtaining token: #{response.status_code}\n#{response.body}" unless response.success?

    # auth key is valid for 5 seconds
    schedule.in(5.seconds) { @auth_key = nil }
    @auth_key = response.headers["X-Auth-Key"]
  end

  def received(bytes, task)
    frame = STOMP::Frame.new(bytes)

    case frame.command
    when .connected?
      client.negotiate(frame)
      @floor_mappings.keys.each do |location_id|
        begin
          subscribe_location(location_id)
        rescue error
          logger.error(exception: error) { "failed to subscribe to #{location_id}, skipping" }
        end
      end
    when .message?
      activity = SpaceActivity.from_json(frame.body_text)
      if space = @spaces[activity.space_id]?
        activity.location_id = space.location_id
        activity.capacity = space.capacity
        activity.name = space.name
        @space_state[activity.space_id] = activity
        self["space-#{activity.space_id}"] = {
          location:     space.location_id,
          name:         space.name,
          capacity:     space.capacity,
          count:        activity.state,
          last_updated: activity.utc_epoch,
        }
        self["last_change"] = Time.utc.to_unix
      else
        # NOTE:: this should never happen
        logger.warn { "unknown space id: #{activity.space_id}" }
      end
    end

    task.try &.success
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "sensor incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "sensor incapable of tracking #{email} or #{username}" }
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "sensor incapable of tracking #{mac_address}" }
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Nil if location && location != "desk"

    loctions = @zone_mappings[zone_id]?
    return [] of Nil unless loctions

    # loc_id is a string
    loctions.flat_map do |loc_id|
      location_id = loc_id.to_i64
      loc_details = @floor_mappings[loc_id]

      @space_state.values.compact_map do |activity|
        next if activity.location_id != location_id || activity.state == 0 || activity.capacity > 1

        {
          location:    activity.capacity == 1 ? "desk" : "area",
          at_location: activity.state,
          map_id:      activity.name,
          level:       loc_details[:level_id],
          building:    loc_details[:building_id],
          capacity:    activity.capacity,
        }
      end
    end
  end
end
