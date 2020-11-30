module Place; end

require "json"
require "oauth2"
require "placeos"

class Place::StaffAPI < PlaceOS::Driver
  descriptive_name "PlaceOS Staff API"
  generic_name :StaffAPI
  description %(helpers for requesting data held in the staff API)

  # The PlaceOS API
  uri_base "https://staff.app.api.com"

  default_settings({
    # PlaceOS API creds, so we can query the zone metadata
    username:     "",
    password:     "",
    client_id:    "",
    redirect_uri: "",
  })

  @place_domain : URI = URI.parse("https://staff.app.api.com")
  @username : String = ""
  @password : String = ""
  @client_id : String = ""
  @redirect_uri : String = ""

  @running_a_spec : Bool = false

  def on_load
    on_update
  end

  def on_update
    # we use the Place Client to query the desk booking data
    @username = setting(String, :username)
    @password = setting(String, :password)
    @client_id = setting(String, :client_id)
    @redirect_uri = setting(String, :redirect_uri)
    @place_domain = URI.parse(config.uri.not_nil!)

    @running_a_spec = setting?(Bool, :running_a_spec) || false
  end

  # ===================================
  # ZONE INFORMATION
  # ===================================
  def zone(zone_id : String)
    placeos_client.zones.fetch zone_id
  end

  # ===================================
  # BOOKINGS QUERY
  # ===================================
  class Booking
    include JSON::Serializable

    property id : Int64

    property user_id : String
    property user_email : String
    property user_name : String
    property asset_id : String
    property zones : Array(String)
    property booking_type : String

    property booking_start : Int64
    property booking_end : Int64

    property timezone : String?
    property title : String?
    property description : String?

    property checked_in : Bool
    property rejected : Bool
    property approved : Bool
  end

  def query_bookings(type : String, period_start : Int64? = nil, period_end : Int64? = nil, zones : Array(String) = [] of String, user : String? = nil)
    # Assumes occuring now
    period_start ||= Time.utc.to_unix
    period_end ||= 30.minutes.from_now.to_unix

    params = {
      "period_start" => period_start.to_s,
      "period_end"   => period_end.to_s,
      "type"         => type,
    }
    params["zones"] = zones.join(",") unless zones.empty?
    params["user"] = user if user && !user.empty?

    # Get the existing bookings from the API to check if there is space
    response = get("/api/staff/v1/bookings", params, {
      "Accept"        => "application/json",
      "Authorization" => token,
    })
    raise "issue loading list of bookings (zones #{zones}): #{response.status_code}" unless response.success?

    Array(Booking).from_json(response.body)
  end

  # For accessing PlaceOS APIs
  protected def placeos_client : PlaceOS::Client
    PlaceOS::Client.new(
      @place_domain,
      token: OAuth2::AccessToken::Bearer.new(token, nil)
    )
  end

  # ===================================
  # PLACEOS AUTHENTICATION:
  # ===================================
  @access_token : String = ""
  @access_expires : Time = Time.unix(0)

  protected def authenticate : String
    uri = @place_domain
    host = uri.port ? "#{uri.host}:#{uri.port}" : uri.host.not_nil!
    origin = "#{uri.scheme}://#{host}"

    # Create oauth client, optionally pass custom URIs if needed,
    # if the authorize or token URIs are not the standard ones
    # (they can also be absolute URLs)
    oauth2_client = OAuth2::Client.new(host, @client_id, "",
      redirect_uri: @redirect_uri,
      authorize_uri: "#{origin}/auth/oauth/authorize",
      token_uri: "#{origin}/auth/oauth/token")

    access_token = oauth2_client.get_access_token_using_resource_owner_credentials(
      @username,
      @password,
      "public"
    ).as(OAuth2::AccessToken::Bearer)

    @access_expires = (access_token.expires_in.not_nil! - 300).seconds.from_now
    @access_token = "Bearer #{access_token.access_token}"
  end

  protected def token : String
    # Don't perform OAuth if we are testing the driver
    return "spec-test" if @running_a_spec
    return @access_token if valid_token?
    authenticate
  end

  protected def valid_token?
    Time.utc < @access_expires
  end
end

# Deal with bad SSL certificate
class OpenSSL::SSL::Context::Client
  def initialize(method : LibSSL::SSLMethod = Context.default_method)
    super(method)

    self.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
      self.default_verify_param = "ssl_server"
    {% end %}
  end
end
