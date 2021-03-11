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

  def get_system(id : String)
    response = get("/api/engine/v2/systems/#{id}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response for system id #{id}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing system #{id}:\n#{response.body.inspect}" }
      raise error
    end
  end

  def systems(q : String? = nil,
              limit : Int32 = 1000,
              offset : Int32 = 0,
              zone_id : String? = nil,
              module_id : String? = nil,
              features : String? = nil,
              capacity : Int32? = nil,
              bookable : Bool? = nil)
    placeos_client.systems.search(
      q: q,
      limit: limit,
      offset: offset,
      zone_id: zone_id,
      module_id: module_id,
      features: features,
      capacity: capacity,
      bookable: bookable
    )
  end

  # Staff details returns the information from AD
  def staff_details(email : String)
    response = get("/api/staff/v1/people/#{email}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response for stafff #{email}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing staff #{email}:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # User details
  # ===================================
  def user(id : String)
    placeos_client.users.fetch(id)
  end

  @[Security(Level::Support)]
  def update_user(id : String, body_json : String) : Nil
    response = patch("/api/engine/v2/users/#{id}", body: body_json, headers: {
      "Accept"        => "application/json",
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "failed to update groups for #{id}: #{response.status_code}" unless response.success?
  end

  @[Security(Level::Support)]
  def resource_token
    response = post("/api/engine/v2/users/resource_token", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # Guest details
  # ===================================
  @[Security(Level::Support)]
  def guest_details(guest_id : String)
    response = get("/api/staff/v1/guests/#{guest_id}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing:\n#{response.body.inspect}" }
      raise error
    end
  end

  # ===================================
  # ZONE METADATA
  # ===================================
  def metadata(id : String, key : String? = nil)
    placeos_client.metadata.fetch(id, key)
  end

  def metadata_children(id : String, key : String? = nil)
    placeos_client.metadata.children(id, key)
  end

  # ===================================
  # ZONE INFORMATION
  # ===================================
  def zone(zone_id : String)
    placeos_client.zones.fetch zone_id
  end

  def zones(q : String? = nil,
            limit : Int32 = 1000,
            offset : Int32 = 0,
            parent : String? = nil,
            tags : Array(String) | String? = nil)
    placeos_client.zones.search(
      q: q,
      limit: limit,
      offset: offset,
      parent: parent,
      tags: tags
    )
  end

  # ===================================
  # MODULE INFORMATION
  # ===================================
  def module(module_id : String)
    response = get("/api/engine/v2/modules/#{module_id}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response for module id #{module_id}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue parsing module #{module_id}:\n#{response.body.inspect}" }
      raise error
    end
  end

  def modules_from_system(system_id : String)
    response = get("/api/engine/v2/modules?control_system_id=#{system_id}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })

    raise "unexpected response for modules for #{system_id}: #{response.status_code}\n#{response.body}" unless response.success?

    begin
      JSON.parse(response.body)
    rescue error
      logger.debug { "issue getting modules for #{system_id}:\n#{response.body.inspect}" }
      raise error
    end
  end

  # TODO: figure out why these 2 methods don't work
  # def module(module_id : String)
  #   placeos_client.modules.fetch module_id
  # end

  # def modules(q : String? = nil,
  #             limit : Int32 = 20,
  #             offset : Int32 = 0,
  #             control_system_id : String? = nil,
  #             driver_id : String? = nil)
  #   placeos_client.modules.search(
  #     q: q,
  #     limit: limit,
  #     offset: offset,
  #     control_system_id: control_system_id,
  #     driver_id: driver_id
  #   )
  # end

  # ===================================
  # BOOKINGS ACTIONS
  # ===================================
  @[Security(Level::Support)]
  def reject(booking_id : String | Int64)
    logger.debug { "rejecting booking #{booking_id}" }
    response = post("/api/staff/v1/bookings/#{booking_id}/reject", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })
    raise "issue rejecting booking #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def approve(booking_id : String | Int64)
    logger.debug { "approving booking #{booking_id}" }
    response = post("/api/staff/v1/bookings/#{booking_id}/approve", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })
    raise "issue approving booking #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_state(booking_id : String | Int64, state : String)
    logger.debug { "updating booking #{booking_id} state to: #{state}" }
    response = post("/api/staff/v1/bookings/#{booking_id}/update_state?state=#{state}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })
    raise "issue updating booking state #{booking_id}: #{response.status_code}" unless response.success?
    true
  end

  @[Security(Level::Support)]
  def booking_check_in(booking_id : String | Int64, state : Bool = true)
    logger.debug { "checking in booking #{booking_id} to: #{state}" }
    response = post("/api/staff/v1/bookings/#{booking_id}/check_in?state=#{state}", headers: {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })
    raise "issue checking in booking #{booking_id}: #{response.status_code}" unless response.success?
    true
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

    property approver_id : String?
    property approver_email : String?
    property approver_name : String?

    property booked_by_id : String
    property booked_by_email : String
    property booked_by_name : String

    property process_state : String?
    property last_changed : Int64?
    property created : Int64?
  end

  def query_bookings(
    type : String,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil
  )
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
    params["email"] = email if email && !email.empty?
    params["state"] = state if state && !state.empty?
    params["created_before"] = created_before.to_s if created_before
    params["created_after"] = created_after.to_s if created_after
    params["approved"] = approved.to_s unless approved.nil?
    params["rejected"] = rejected.to_s unless rejected.nil?

    # Get the existing bookings from the API to check if there is space
    response = get("/api/staff/v1/bookings", params, {
      "Accept"        => "application/json",
      "Authorization" => "Bearer #{token}",
    })
    raise "issue loading list of bookings (zones #{zones}): #{response.status_code}" unless response.success?

    # Just parse it here instead of using the Bookings object
    # it will be parsed into an object on the far end
    JSON.parse(response.body)
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
    @access_token = access_token.access_token
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
