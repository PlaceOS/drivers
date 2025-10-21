require "placeos-driver"
require "./wireless_manager_models"
require "http"
require "json"

# Documentation: https://apihelp.wifi.arista.com/usecases#toc1
# https://apihelp.wifi.arista.com/api/wm/clients/15

class Arista::WirelessManagerAPI < PlaceOS::Driver
  descriptive_name "Arista Wireless Manager"
  generic_name :Arista_Wifi

  uri_base "https://launchpad.wifi.arista.com/"
  description %(
    add the api key id and secret and use launch pad
    to discover the wireless manager service URI
  )

  default_settings({
    key_id:    "KEY-ATNxxxxxxxx",
    key_value: "ddfxxxxxxxx",
    key_type:  "apikeycredentials",

    # every 3 seconds
    polling_seconds: 3,
    _poll_locations: [28],
  })

  def on_load
    transport.before_request do |request|
      request.headers["Content-Type"] = "application/json"
      request.headers["Accept"] = "application/json"
    end

    on_update
  end

  def on_update
    @key_type = setting?(String, :key_type).presence || "apikeycredentials"
    @key_value = setting(String, :key_value)
    @key_id = setting(String, :key_id)

    # Sessions should last 1 hours
    schedule.clear
    schedule.every(50.minutes, immediate: true) do
      @authenticated = false
      new_session
    end

    polling_sec = setting?(UInt32, :polling_seconds) || 3_u32
    polling_locs = setting?(Array(Int64), :poll_locations) || [] of Int64

    if !polling_locs.empty?
      schedule.every(polling_sec.seconds) do
        poll(polling_locs)
      end
    end
  end

  getter? authenticated : Bool = false
  getter key_type : String = ""
  getter key_id : String = ""
  @key_value : String = ""
  getter position_cache : Hash(Int64, Array(ClientDetails)) = {} of Int64 => Array(ClientDetails)

  # make this request to obtain the base URI for the module
  def launchpad_service_locations
    response = ::HTTP::Client.post("https://launchpad.wifi.arista.com/api/v2/session", body: {
      type:     key_type,
      keyId:    key_id,
      keyValue: @key_value,
      timeout:  3600,
    }.to_json)
    raise "session failed with: #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?

    logger.debug { "session established: #{response.inspect}" }

    response_headers = response.headers
    logger.debug { "response headers: #{response_headers.inspect}" }
    cookies = ::HTTP::Cookies.new
    cookies.fill_from_server_headers(response_headers)

    headers = cookies.add_request_headers(HTTP::Headers.new)
    response2 = ::HTTP::Client.get("https://launchpad.wifi.arista.com/rest/api/v2/services?type=amc", headers: headers)
    raise "services failed with: #{response2.status} (#{response2.status_code})\n#{response2.body}" unless response2.success?
    JSON.parse(response2.body)
  end

  @mutex = Mutex.new

  def new_session
    @mutex.synchronize do
      return if authenticated?

      response = post("/wifi/api/session", body: {
        type:             key_type,
        keyId:            key_id,
        keyValue:         @key_value,
        clientIdentifier: "PlaceOS",
        timeout:          3600,
      }.to_json)

      if response.success?
        self[:authenticated] = @authenticated = true
      else
        self[:authenticated] = @authenticated = false
        queue.set_connected(false)
        raise "session failed with: #{response.status} (#{response.status_code})\n#{response.body}"
      end
    end
  rescue error
    logger.warn(exception: error) { "error creating session" }
    self[:authenticated] = @authenticated = false
    queue.set_connected(false)
  end

  protected def check(response)
    return response if response.success?
    @authenticated = false if response.status.unauthorized?
    raise "locations failed with: #{response.status} (#{response.status_code})\n#{response.body}"
  end

  # The build structure.
  def locations : Location
    new_session unless authenticated?

    response = check get("/new/wifi/api/locations")
    Location.from_json(response.body)
  end

  def locations_flatten
    locations.flatten.compact_map do |loc|
      {
        id:        loc.id,
        parent_id: loc.parent_id,
        name:      loc.name,
        timezone:  loc.timezone,
        geo_info:  loc.geo_info,
      }
    end
  end

  def client_positions(at_location : String | Int64? = nil)
    new_session unless authenticated?

    query = URI::Params.build do |form|
      form.add("pagesize", "250")
      form.add("filter", %({"property":"activestatus","operator":"=","value":[true]}))
      form.add("locationid", at_location.to_s) if at_location
    end

    locations = [] of ClientDetails

    # requires two requests per-page
    next_page = URI.parse("/wifi/api/clients/locationtracking?#{query}")
    loop do
      break unless next_page

      # Request the locations
      response = check post(next_page.request_target)

      begin
        loc_req = LocationsRequest.from_json(response.body)

        # get the location data
        data_url = URI.parse(loc_req.result_url).request_target
        loop do
          # always takes some time for the results to be gathered
          sleep 200.milliseconds
          poll_response = check get(data_url)

          # the locations request is still being processed
          next if poll_response.body.starts_with?(%({"status":"RUNNING"))

          begin
            # process extract the device locations
            loc_response = LocationTracking.from_json(poll_response.body)
            locations.concat loc_response.results.flat_map(&.clients)
          rescue error : JSON::ParseException
            logger.error(exception: error) { "error parsing tracking results:\n#{poll_response.body.inspect}" }
            raise "error parsing tracking results"
          end

          break
        end
      rescue error : JSON::ParseException
        logger.error(exception: error) { "error parsing location request:\n#{response.body.inspect}" }
        raise "error parsing location request"
      end

      # get the next page
      next_page = loc_req.next_uri
    end

    locations
  end

  @mutex = Mutex.new

  protected def poll(locations : Array(Int64))
    cached = Hash(Int64, Array(ClientDetails)).new { |hash, key| hash[key] = [] of ClientDetails }

    locations.each do |loc|
      positions = client_positions(loc)
      positions.each do |details|
        cached[details.device.location.id] << details
      end
    end

    @mutex.synchronize do
      @position_cache = cached
    end

    cached.each do |level, clients|
      self["location_#{level}"] = clients
    end
  end

  def cached_positions(at_location : String | Int64)
    @mutex.synchronize do
      position_cache[at_location.to_i64]? || [] of ClientDetails
    end
  end

  def locate(username : String) : ClientDetails?
    # should be able to use a filter for realtime results
    # filter={"property":"username","operator":"=","value":["email@org.com"]}
    check = username.downcase.presence
    return nil unless check

    position_cache.each_value do |details|
      if found = details.find { |client| client.device.username == check }
        return found
      end
    end
    nil
  end

  def macs_assigned_to(username : String) : Array(String)
    macs = [] of String
    check = username.downcase.presence
    return macs unless check

    position_cache.each_value do |details|
      details.each do |client|
        if client.device.username == check
          macs << client.device.mac
        end
      end
    end
    macs
  end

  def ownership_of(mac_address : String) : ClientDetails?
    return nil unless mac_address.presence
    mac = format_mac(mac_address)

    position_cache.each_value do |details|
      if found = details.find { |client| client.device.mac == mac }
        return found
      end
    end
    nil
  end

  protected def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
