require "uri"
require "json"
require "link-header"
require "placeos-driver"
require "./scanning_api"

class Cisco::Meraki::Dashboard < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Meraki Dashboard"
  generic_name :Dashboard
  uri_base "https://api.meraki.com"
  description %(
    for more information visit:
      * Dashboard API: https://documentation.meraki.com/zGeneral_Administration/Other_Topics/The_Cisco_Meraki_Dashboard_API
      * Scanning API: https://developer.cisco.com/meraki/scanning-api/#!introduction/scanning-api

    NOTE:: API Call volume is rate limited to 5 calls per second per organization
  )

  default_settings({
    meraki_validator: "configure if scanning API is enabled",
    meraki_secret:    "configure if scanning API is enabled",
    meraki_api_key:   "configure for the dashboard API",

    # Max requests a second made to the dashboard
    rate_limit:    4,
    debug_payload: false,
  })

  def on_load
    spawn { rate_limiter }
    on_update
  end

  @scanning_validator : String = ""
  @scanning_secret : String = ""
  @api_key : String = ""

  @rate_limit : Int32 = 4
  @channel : Channel(Nil) = Channel(Nil).new(1)
  @queue_lock : Mutex = Mutex.new
  @queue_size = 0
  @wait_time : Time::Span = 300.milliseconds

  @debug_payload : Bool = false

  def on_update
    @scanning_validator = setting?(String, :meraki_validator) || ""
    @scanning_secret = setting?(String, :meraki_secret) || ""
    @api_key = setting?(String, :meraki_api_key) || ""

    @rate_limit = setting?(Int32, :rate_limit) || 4
    @wait_time = 1.second / @rate_limit

    @debug_payload = setting?(Bool, :debug_payload) || false
  end

  # Perform fetch with the required API request limits in place
  @[Security(PlaceOS::Driver::Level::Support)]
  def fetch(location : String)
    req(location, &.body)
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def fetch_all(location : String)
    responses = [] of String
    req_all_pages(location) { |response| responses << response.body }
    responses
  end

  protected def req(location : String)
    if (@wait_time * @queue_size) > 10.seconds
      raise "wait time would be exceeded for API request, #{@queue_size} requests already queued"
    end

    @queue_lock.synchronize { @queue_size += 1 }
    @channel.receive
    @queue_lock.synchronize { @queue_size -= 1 }

    headers = HTTP::Headers{
      "X-Cisco-Meraki-API-Key" => @api_key,
      "Content-Type"           => "application/json",
      "Accept"                 => "application/json",
      "User-Agent"             => "PlaceOS/2.0 PlaceTechnology",
    }

    uri = URI.parse(location)
    response = if uri.host.nil?
                 get(location, headers: headers)
               else
                 HTTP::Client.get(location, headers: headers)
               end

    if response.success?
      yield response
    elsif response.status.found?
      # Meraki might return a `302` on GET requests
      response = HTTP::Client.get(response.headers["Location"], headers: headers)
      if response.success?
        yield response
      else
        raise "request #{location} failed with status: #{response.status_code}"
      end
    else
      raise "request #{location} failed with status: #{response.status_code}"
    end
  end

  protected def req_all_pages(location : String) : Nil
    next_page = location

    loop do
      break unless next_page

      next_page = req(next_page) do |response|
        yield response
        LinkHeader.new(response)["next"]?
      end
    end
  end

  EMPTY_HEADERS    = {} of String => String
  SUCCESS_RESPONSE = {HTTP::Status::OK, EMPTY_HEADERS, nil}

  @[Security(PlaceOS::Driver::Level::Support)]
  def organizations
    req("/api/v1/organizations?perPage=1000") do |response|
      Array(Organization).from_json(response.body)
    end
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def networks(organization_id : String)
    nets = [] of Network
    req_all_pages("/api/v1/organizations/#{organization_id}/networks?perPage=1000") do |response|
      nets.concat Array(Network).from_json(response.body)
    end
    nets
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def poll_clients(network_id : String? = nil, timespan : UInt32 = 900_u32)
    clients = [] of Client
    req_all_pages "/api/v1/networks/#{network_id}/clients?perPage=1000&timespan=#{timespan}" do |response|
      clients.concat Array(Client).from_json(response.body)
    end
    clients
  end

  # Webhook endpoint for scanning API, expects version 3
  def scanning_api(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "scanning API received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_payload

    # Return the scanning API validator code on a GET request
    return {HTTP::Status::OK.to_i, EMPTY_HEADERS, @scanning_validator} if method == "GET"

    # Check the version matches
    if !body.starts_with?(%({"version":"3.0"))
      logger.warn { "unknown scanning API message received:\n#{body[0..96]}" }
      return SUCCESS_RESPONSE
    end

    # Parse the data posted
    begin
      seen = DevicesSeen.from_json(body)
      logger.debug { "parsed meraki payload" }

      # We're only interested in Wifi at the moment
      if seen.message_type != "WiFi"
        logger.debug { "ignoring message type: #{seen.message_type}" }
        return SUCCESS_RESPONSE
      end

      # Check the secret matches
      raise "secret mismatch, sent: #{seen.secret}" unless seen.secret == @scanning_secret

      self[seen.data.network_id] = seen.data.observations
    rescue e
      logger.error { "failed to parse meraki scanning API payload\n#{e.inspect_with_backtrace}" }
      logger.debug { "failed payload body was\n#{body}" }
    end

    # Return a 200 response
    SUCCESS_RESPONSE
  end

  protected def rate_limiter
    loop do
      begin
        @channel.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep @wait_time
      end
    end
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter }
  end
end
