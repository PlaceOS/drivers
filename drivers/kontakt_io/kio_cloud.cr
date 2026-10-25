require "placeos-driver"
require "simple_retry"
require "./kio_cloud_models"

class KontaktIO::KioCloud < PlaceOS::Driver
  # Discovery Information
  uri_base "https://apps.cloud.us.kontakt.io"
  descriptive_name "Kontakt IO Cloud API"
  generic_name :KontaktIO

  default_settings({
    kio_api_key: "Sign in to Kio Cloud > select Users > select Security > copy the Server API Key",
    poll_every:  30,
  })

  # raised when the API responds with 429 Too Many Requests
  class RateLimited < Exception
    getter retry_after : Time::Span?

    def initialize(message, @retry_after = nil)
      super(message)
    end
  end

  ROOMS_CACHE_PERIOD = 10.minutes
  MIN_BACKOFF        = 30.seconds
  MAX_BACKOFF        = 10.minutes

  @api_key : String = %()

  def on_update
    @api_key = setting(String, :kio_api_key)
    @rooms_cache = nil
    @backoff_until = nil
    @backoff = nil

    poll_every = (setting?(Int32, :poll_every) || 30).seconds
    schedule.clear
    schedule.every(poll_every) { cache_occupancy_counts }
  end

  # Note:: there is a limit of 40 requests a second, however we are unlikely to hit this
  protected def make_request(
    method, path, body : ::HTTP::Client::BodyType = nil,
    params : URI::Params = URI::Params.new,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    &
  ) : String
    # handle auth
    headers["Api-Key"] = @api_key
    headers["Content-Type"] = "application/json"

    # deal with result sizes and pagination
    params["size"] = "500"
    page = 0

    loop do
      params["page"] = page.to_s

      path_params = "#{path}?#{params.map { |(key, value)| "#{key}=#{value}" }.join('&')}"
      logger.debug { "requesting: #{method} #{path_params}" }
      response = http(method, path_params, body, headers: headers)

      logger.debug { "request returned:\n#{response.body}" }
      case response.status_code
      when 303
        # TODO:: follow the redirect
      when 401
        logger.warn { "The API Key is invalid or disabled" }
      when 403
        logger.warn { "User who created the API no longer has access to the Kio Cloud account or their user role doesn't allow access to the endpoint. Device error if the endpoint is not available for the device model." }
      end

      if response.status_code == 429
        retry_after = response.headers["Retry-After"]?.try(&.to_i?).try(&.seconds)
        raise RateLimited.new("request #{path} rate limited (429), retry after: #{retry_after || "unspecified"}", retry_after)
      end

      unless response.success?
        begin
          error = JSON.parse response.body
          message = error["message"]?.try(&.as_s) || response.body
          raise "request #{path}?#{params} failed with #{response.status_code}:\n#{message}"
        rescue
          raise "request #{path}?#{params} failed with #{response.status_code}:\n#{response.body}"
        end
      end

      if page_details = yield response.body
        page += 1
        next unless page >= page_details.total_pages
      end
      break response.body
    end
  end

  protected def make_request(
    method, path, body : ::HTTP::Client::BodyType = nil,
    params : URI::Params = URI::Params.new,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
  ) : String
    make_request(method, path, body, params, headers) { nil }
  end

  def colocations(mac_address : String, start_time : Int64? = nil, end_time : Int64? = nil) : Array(Tracking)
    # max range is 21 days, we default to 20
    ending = end_time ? Time.unix(end_time) : 10.minutes.ago
    starting = start_time ? Time.unix(start_time) : (ending - 20.days)
    tracking = [] of Tracking

    make_request("GET", "/v3/novid/colocations", params: URI::Params{
      # mac address needs to be uppercase and pretty formed for this request
      "trackingId" => format_mac(mac_address).upcase.scan(/\w{2}/).map(&.to_a.first).join(':'),
      "startTime"  => starting.to_rfc3339,
      "endTime"    => ending.to_rfc3339,
    }) do |data|
      resp = Response(Tracking).from_json(data)
      tracking.concat resp.content
      resp.page
    end
    tracking
  end

  def find(mac_address : String) : Position?
    data = make_request("GET", "/v2/positions", params: URI::Params{
      # mac address needs to be lowercase for this request (according to the API)
      "trackingId" => format_mac(mac_address),
    })
    Response(Position).from_json(data).content.first?
  end

  def campuses : Array(Campus)
    campuses = [] of Campus
    make_request("GET", "/v2/locations/campuses") do |data|
      resp = Response(Campus).from_json(data)
      campuses.concat resp.content
      resp.page
    end
    campuses
  end

  def rooms : Array(Room)
    rooms = [] of Room
    make_request("GET", "/v2/locations/rooms") do |data|
      resp = Response(Room).from_json(data)
      rooms.concat resp.content
      resp.page
    end
    rooms
  end

  def room_occupancy : Array(RoomOccupancy)
    room_occupancy = [] of RoomOccupancy
    make_request("GET", "/v3/occupancy/rooms") do |data|
      resp = Response(RoomOccupancy).from_json(data)
      room_occupancy.concat resp.content
      resp.page
    end
    room_occupancy
  end

  def telemetry(tracking_ids : Array(String)) : Array(Telemetry)
    telemetry = [] of Telemetry

    params = URI::Params.new
    params["endTime"] = Time.utc.to_rfc3339(fraction_digits: 3)
    params["startTime"] = 2.minutes.ago.to_rfc3339(fraction_digits: 3)
    params["trackingId"] = tracking_ids.map(&.strip.downcase).join(",") unless tracking_ids.empty?

    make_request("GET", "/v3/telemetry", params: params) do |data|
      resp = Response(Telemetry).from_json(data)
      telemetry.concat resp.content
      resp.page
    end
    telemetry
  end

  # ===================================
  # Caching sensor data
  # ===================================
  getter occupancy_cache : Hash(Int64, RoomOccupancy) = {} of Int64 => RoomOccupancy

  @rooms_cache : Array(Room)? = nil
  @rooms_cached_at : Time = Time.utc
  @backoff_until : Time? = nil
  @backoff : Time::Span? = nil

  # rooms rarely change so we avoid requesting them on every poll
  protected def cached_rooms : Array(Room)
    cache = @rooms_cache
    return cache if cache && @rooms_cached_at > ROOMS_CACHE_PERIOD.ago
    cache = rooms
    @rooms_cached_at = Time.utc
    @rooms_cache = cache
  end

  protected def cache_occupancy_counts
    if (backoff_until = @backoff_until) && backoff_until > Time.utc
      logger.debug { "skipping poll, rate limited until #{backoff_until}" }
      return
    end

    update_occupancy_cache
    @backoff = nil
    @backoff_until = nil
    self[:rate_limited_until] = nil
  rescue error : RateLimited
    # double the backoff each time we're rate limited, unless the API tells us how long to wait
    backoff = error.retry_after || (@backoff.try { |period| period * 2 } || MIN_BACKOFF).clamp(MIN_BACKOFF, MAX_BACKOFF)
    @backoff = backoff
    @backoff_until = resume_at = backoff.from_now
    self[:rate_limited_until] = resume_at.to_unix
    logger.warn { "#{error.message}, pausing polling for #{backoff.total_seconds.to_i}s" }
  end

  protected def update_occupancy_cache
    sensor_to_room = {} of String => Room
    cached_rooms.each do |room|
      room.room_sensor_ids.each do |sensor_id|
        sensor_to_room[sensor_id] = room
      end
    end

    cache = Hash(Int64, RoomOccupancy).new(sensor_to_room.size) do |_hash, key|
      raise KeyError.new(%(Missing hash key: "#{key}"))
    end

    # 3rd party motion sensors
    recent_motion = 180_i64
    sensor_to_room.keys.each_slice(10) do |keys|
      begin
        # retrying a rate limited request only makes things worse
        SimpleRetry.try_to(max_attempts: 3, base_interval: 200.milliseconds, raise_on: RateLimited) do
          telemetry_data = telemetry(keys)
          telemetry_data.each do |sensor|
            seconds_since = sensor.seconds_since_motion || 3.days.total_seconds.to_i
            room = sensor_to_room[sensor.id]
            self["room-#{room.id}"] = cache[room.id] = room.to_room_occupancy(seconds_since <= recent_motion, sensor.timestamp)
          end
        end
      rescue error : RateLimited
        raise error
      rescue error
        # keep the previous values for these rooms and continue with the remaining sensors
        logger.warn(exception: error) { "failed to obtain telemetry for sensors #{keys}" }
        keys.each do |sensor_id|
          room_id = sensor_to_room[sensor_id].id
          if previous = @occupancy_cache[room_id]?
            cache[room_id] = previous
          end
        end
      end
    end

    # occupancy counters
    occupancy = room_occupancy
    occupancy.each { |room| self["room-#{room.room_id}"] = cache[room.room_id] = room }
    @occupancy_cache = cache
    self[:occupancy_cached_at] = Time.utc.to_unix
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  def event_hub(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "scanning API received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body }
  end

  def create_channel(name : String, uri : String)
    make_request("POST", "/v3/channels", body: {
      status:  :active,
      name:    name,
      channel: {
        type:                "eventHub",
        endpoint:            uri,
        streamName:          name,
        accessKey:           "test",
        secretKey:           "test",
        region:              "test",
        sharedAccessKeyName: "test",
        eventHubName:        "test",
        sharedAccessKey:     "test",
      },
    }.to_json)
  end

  def delete_channel(id : Int32 | String)
    make_request("DELETE", "/v3/channels", params: URI::Params{
      "id" => id.to_s,
    })
  end
end
