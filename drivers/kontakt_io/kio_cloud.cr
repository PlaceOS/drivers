require "placeos-driver"
require "./kio_cloud_models"

class KontaktIO::KioCloud < PlaceOS::Driver
  # Discovery Information
  uri_base "https://apps.cloud.us.kontakt.io"
  descriptive_name "Kontakt IO Cloud API"
  generic_name :KontaktIO

  default_settings({
    kio_api_key: "Sign in to Kio Cloud > select Users > select Security > copy the Server API Key",
  })

  def on_load
    on_update
  end

  @api_key : String = ""

  def on_update
    @api_key = setting(String, :kio_api_key)
  end

  # Note:: there is a limit of 40 requests a second, however we are unlikely to hit this
  protected def make_request(
    method, path, body : ::HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new
  ) : String
    logger.debug { "requesting: #{method} #{path}" }

    # handle auth
    headers["Api-Key"] = @api_key
    headers["Content-Type"] = "application/json"

    # deal with result sizes and pagination
    params["size"] = "10000"
    # params["page"] = page_num.to_s

    response = http(method, path, body, params, headers)

    logger.debug { "request returned:\n#{response.body}" }
    case response.status_code
    when 303
      # TODO:: follow the redirect
    when 401
      logger.warn { "The API Key is invalid or disabled" }
    when 403
      logger.warn { "User who created the API no longer has access to the Kio Cloud account or their user role doesn't allow access to the endpoint. Device error if the endpoint is not available for the device model." }
    end

    raise "request #{path} failed with status: #{response.status_code}" unless response.success?

    response.body
  end

  def find(mac_address : String) : Position?
    data = make_request("GET", "/v2/positions", params: {
      "trackingId" => format_mac(mac_address),
    })
    Response(Position).from_json(data).content.first?
  end

  def campuses : Array(Campus)
    data = make_request("GET", "/v2/locations/campuses")
    Response(Campus).from_json(data).content
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
    make_request("DELETE", "/v3/channels", params: {
      "id" => id.to_s,
    })
  end
end
