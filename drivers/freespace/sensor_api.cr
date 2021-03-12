module Freespace; end

require "uri"
require "stomp"
# https://aca.im/driver_docs/Freespace/Freespace%20Socket%20API-V1.2.pdf

class Freespace::SensorAPI < PlaceOS::Driver
  # Discovery Information
  generic_name :Freespace
  descriptive_name "Freespace Websocket API"

  uri_base "https://_instance_.afreespace.com"

  default_settings({
    username: "user",
    password: "pass",
    location: "id",
  })

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @location = setting(String | Int32, :location)
  end

  # We need an API key to connect to the websocket
  def websocket_headers
    HTTP::Headers{
      "X-Auth-Key" => get_token,
    }
  end

  getter! client : STOMP::Client
  @auth_key : String? = nil

  def connected
    # Send the CONNECT message
    hostname = URI.parse(config.uri.not_nil!).hostname
    @client = STOMP::Client.new(hostname)
    send(client.stomp.to_s)

    schedule.clear
    schedule.every(10.seconds) { heart_beat }
  end

  def disconnected
    schedule.clear
    @auth_key = @client = nil
  end

  def heart_beat
    send(client.send("/beat/#{Time.utc.to_unix}").to_s, wait: false, priority: 0)
  end

  @spaces : Hash(String, Space) = {} of String => Space

  @[Security(Level::Support)]
  def subscribe_location(location_id)
    response = post(
      "/api/locations/#{location_id}/spaces",
      HTTP::Headers{
        "X-Auth-Key"   => get_token,
        "Content-Type" => "application/json",
        "Accept"       => "application/json",
      }, body: {
        username: @username,
        password: @password,
      }.to_json
    )

    # TODO:: disconnect if we fail to subscribe
    raise "issue subscribing to location: #{response.status_code}\n#{response.body}" unless response.success?

    # Array of

    response.body
  end

  # Alternative to using basic auth, but here really only for testing with postman
  @[Security(Level::Support)]
  def get_token : String
    auth_key = @auth_key
    return auth_key if auth_key

    response = post(
      "/login",
      HTTP::Headers{
        "Content-Type" => "application/json",
        "Accept"       => "application/json",
      }, body: {
        username: @username,
        password: @password,
      }.to_json
    )
    raise "issue obtaining token: #{response.status_code}\n#{response.body}" unless response.success?
    schedule.in(5.seconds) { @auth_key = nil }
    @auth_key = response.headers["X-Auth-Key"]
  end

  @space_state : Hash(String, Bool) = {} of String => Bool

  def received(bytes, task)
    frame = STOMP::Frame.new(bytes)

    case frame.command
    when .connected?
      client.negotiate(frame)
      subscribe_location(@location)
    when .message?
      space = SpaceActivity.from_json(frame.body_text)
      @space_state[space.space_id] = space
      self[space.space_id] = space.presence?
    end

    task.try &.success
  end

  class SpaceActivity
    include JSON::Serializable

    property id : Int64

    @[JSON::Field(key: "spaceId")]
    property space_id : Int64

    @[JSON::Field(key: "utcEpoch")]
    property utc_epoch : Int64
    property state : Int32

    def presence?
      @state == 1
    end
  end
end
