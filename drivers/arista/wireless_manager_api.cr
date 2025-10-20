require "placeos-driver"
require "./wireless_manager_models"

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
  end

  getter? authenticated : Bool = false
  getter key_type : String = ""
  getter key_id : String = ""
  @key_value : String = ""

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

  def locations
    new_session unless authenticated?

    response = check get("/new/wifi/api/locations")
    Location.from_json(response.body)
  end

  def client_positions(at_location : String | Int64? = nil)
    new_session unless authenticated?

    query = URI::Params.build do |form|
      form.add("pagesize", "1000")
      form.add("filter", %({"property":"activestatus","operator":"=","value":[true]}))
      form.add("locationid", at_location.to_s) if at_location
    end

    locations = [] of ClientDetails

    # requires two requests per-page
    next_page = URI.parse("/new/wifi/api/locations?#{query}")
    loop do
      break unless next_page

      # Request the locations
      response = check post(next_page.request_target)
      loc_req = LocationsRequest.from_json(response.body)

      # get the location data
      data_url = URI.parse(loc_req.result_url).request_target
      response = check get(data_url)

      # process extract the device locations
      loc_response = LocationTracking.from_json(response.body)
      locations.concat loc_response.results.flat_map(&.clients)

      # get the next page
      next_page = loc_req.next_uri
    end

    locations
  end
end
