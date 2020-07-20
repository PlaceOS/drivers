module Cisco; end

module Cisco::Meraki; end

require "json"
require "./scanning_api"

class Cisco::Meraki::Dashboard < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Meraki Dashboard"
  generic_name :Dashboard
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
  })

  def on_load
    on_update
  end

  @scanning_validator : String = ""
  @scanning_secret : String = ""
  @api_key : String = ""

  def on_update
    # NOTE:: base URI https://api.meraki.com

    @scanning_validator = setting?(String, :meraki_validator) || ""
    @scanning_secret = setting?(String, :meraki_secret) || ""
    @api_key = setting?(String, :meraki_api_key) || ""
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

  EMPTY_HEADERS = {} of String => String

  # Webhook endpoint for scanning API, expects version 3
  def scanning_api(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "scanning API received: #{method},\nheaders #{headers},\nbody #{body}" }

    # Return the scanning API validator code on a GET request
    return {HTTP::Status::OK.to_i, EMPTY_HEADERS, @scanning_validator} if method == "GET"

    begin
      seen = DevicesSeen.from_json(body)
      logger.debug { "parsed meraki payload" }
    rescue e
      logger.error { "failed to parse meraki scanning API payload" }
    end

    # Return a 200 response
    {HTTP::Status::OK.to_i, EMPTY_HEADERS, nil}
  end
end
