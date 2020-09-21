module Cisco; end

module Cisco::Meraki; end

require "json"
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

    # We will always accept a reading with a confidence lower than this
    acceptable_confidence: 5.0,

    # Max Uncertainty in meters - we don't accept positions that are less certain
    maximum_uncertainty: 25.0,

    # Age we keep a confident value (without drifting towards less confidence)
    maximum_confidence_time: 40,

    # Age at which we discard a drifting value (accepting a less confident value)
    maximum_drift_time: 160,
  })

  def on_load
    on_update
  end

  @scanning_validator : String = ""
  @scanning_secret : String = ""
  @api_key : String = ""

  @acceptable_confidence : Float64 = 5.0
  @maximum_uncertainty : Float64 = 25.0
  @maximum_confidence_time : Time::Span = 40.seconds
  @maximum_drift_time : Time::Span = 160.seconds

  @time_multiplier : Float64 = 0.0
  @confidence_multiplier : Float64 = 0.0

  def on_update
    @scanning_validator = setting?(String, :meraki_validator) || ""
    @scanning_secret = setting?(String, :meraki_secret) || ""
    @api_key = setting?(String, :meraki_api_key) || ""

    @acceptable_confidence = setting?(Float64, :acceptable_confidence) || 5.0
    @maximum_uncertainty = setting?(Float64, :maximum_uncertainty) || 25.0
    @maximum_confidence_time = (setting?(Int32, :maximum_confidence_time) || 40).seconds
    @maximum_drift_time = (setting?(Int32, :maximum_drift_time) || 160).seconds

    # How much confidence do we have in this new value, relative to an old confident value
    @time_multiplier = 1.0_f64 / (@maximum_drift_time.to_i - @maximum_confidence_time.to_i).to_f64
    @confidence_multiplier = 1.0_f64 / (@maximum_uncertainty.to_i - @acceptable_confidence.to_i).to_f64
  end

  # Perform fetch with the required API request limits in place
  @[Security(PlaceOS::Driver::Level::Support)]
  def fetch(location : String)
    queue delay: 200.milliseconds do |task|
      response = get(location, headers: {
        "X-Cisco-Meraki-API-Key" => @api_key,
        "Content-Type"           => "application/json",
        "Accept"                 => "application/json",
      })
      if response.success?
        task.success(response.body)
      elsif response.status.found?
        # Meraki might return a `302` on GET requests
        response = HTTP::Client.get(response.headers["Location"], headers: HTTP::Headers{
          "X-Cisco-Meraki-API-Key" => @api_key,
          "Content-Type"           => "application/json",
          "Accept"                 => "application/json",
        })
        if response.success?
          task.success(response.body)
        else
          task.abort "request #{location} failed with status: #{response.status_code}"
        end
      else
        task.abort "request #{location} failed with status: #{response.status_code}"
      end
    end
  end

  EMPTY_HEADERS    = {} of String => String
  SUCCESS_RESPONSE = {HTTP::Status::OK, EMPTY_HEADERS, nil}

  class Lookup
    include JSON::Serializable

    property time : Time
    property mac : String

    def initialize(@time, @mac)
    end
  end

  # MAC Address => Location
  @locations : Hash(String, Location) = {} of String => Location
  @ip_lookup : Hash(String, Lookup) = {} of String => Lookup

  def lookup_ip(address : String)
    @ip_lookup[address.downcase]?
  end

  def locate_mac(address : String)
    @locations[format_mac(address)]?
  end

  @[Security(PlaceOS::Driver::Level::Support)]
  def inspect_state
    logger.debug {
      "IP Mappings: #{@ip_lookup.inspect}\nMAC Locations: #{@locations.inspect}"
    }
    {ip_mappings: @ip_lookup.size, tracking: @locations.size}
  end

  # Webhook endpoint for scanning API, expects version 3
  def scanning_api(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "scanning API received: #{method},\nheaders #{headers},\nbody #{body}" }

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

      # Extract coordinate data against the MAC address and save IP address mappings
      observations = seen.data.observations.reject(&.locations.empty?)

      ignore_older = @maximum_drift_time.ago
      drift_older = @maximum_confidence_time.ago
      observations.each do |observation|
        client_mac = format_mac(observation.client_mac)
        existing = @locations[client_mac]?

        location = parse(existing, ignore_older, drift_older, observation.latest_record.time, observation.locations)
        @locations[client_mac] = location if location
        update_ipv4(observation)
        update_ipv6(observation)
      end
    rescue e
      logger.error { "failed to parse meraki scanning API payload\n#{e.inspect_with_backtrace}" }
    end

    # Return a 200 response
    SUCCESS_RESPONSE
  end

  protected def parse(existing, ignore_older, drift_older, latest, locations) : Location?
    if existing_time = existing.try &.time
      existing = nil if existing_time < ignore_older
    end

    # remove junk
    locations = locations.reject do |loc|
      loc.get_x.nil? || loc.variance > @maximum_uncertainty || loc.time < ignore_older
    end

    return existing if locations.empty?

    # ensure oldest -> newest
    locations = locations.sort { |a, b| a.time <=> b.time }

    # estimate the location given the current observations
    location = existing || locations.shift
    locations.each do |new_loc|
      next unless new_loc.time > location.time

      # If acceptable then this is newer
      if new_loc.variance < @acceptable_confidence
        location = new_loc
        next
      end

      # if more accurate and newer then we'll take this
      if new_loc.variance < location.variance
        location = new_loc
        next
      end

      # should we drift the older location towards a less accurate newer location
      if location.time < drift_older
        # has the floor changed, we should probably accept the newer less accurate location
        if location.floor_plan_id != new_loc.floor_plan_id
          location = new_loc
          next
        end

        new_uncertainty = new_loc.variance
        old_uncertainty = location.variance

        confidence_factor = 1.0 - (@confidence_multiplier * (new_uncertainty - @acceptable_confidence))
        confidence_factor = 0.0 if confidence_factor < 0

        time_diff = new_loc.time.to_unix - location.time.to_unix
        time_factor = @time_multiplier * (time_diff - @maximum_confidence_time.to_i).to_f
        time_factor = 0.0 if time_factor < 0

        # Average of the confidence factors
        average_multiplier = (confidence_factor + time_factor) / 2.0

        new_x = new_loc.x!
        new_y = new_loc.y!
        old_x = location.x!
        old_y = location.y!

        # 7.5 =   5   + ((  10  -  5   ) * 0.5)
        new_x = old_x + ((new_x - old_x) * average_multiplier)
        new_y = old_y + ((new_y - old_y) * average_multiplier)
        new_uncertainty = old_uncertainty + ((new_uncertainty - old_uncertainty) * average_multiplier)

        new_loc.x = new_x
        new_loc.y = new_y
        new_loc.variance = new_uncertainty
        location = new_loc
      end
    end
  end

  protected def update_ipv4(observation)
    ipv4 = observation.ipv4
    return unless ipv4
    time = observation.latest_record.time
    lookup = @ip_lookup[ipv4]? || Lookup.new(time, observation.client_mac)
    lookup.time = time
    lookup.mac = observation.client_mac
    @ip_lookup[ipv4] = lookup
  end

  protected def update_ipv6(observation)
    ipv6 = observation.ipv6.try &.downcase
    return unless ipv6
    time = observation.latest_record.time
    lookup = @ip_lookup[ipv6]? || Lookup.new(time, observation.client_mac)
    lookup.time = time
    lookup.mac = observation.client_mac
    @ip_lookup[ipv6] = lookup
  end

  def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
