require "placeos-driver"
require "./models/internal_user"
require "uuid"

# Tested with Cisco ISE API v3.1
# https://developer.cisco.com/docs/identity-services-engine/v1/#!internaluser

class Cisco::Ise::NetworkAccess < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco ISE REST API"
  generic_name :NetworkAccess
  uri_base "https://ise-pan:9060/ers/config"

  default_settings({
    username:        "user",
    password:        "pass",
    portal_id:       "Required for Guest Users, ask cisco ISE admins",
    timezone:        "UTC",
    guest_type:      "Required for Guest Users, ask cisco ISE admins for valid subset of values", # e.g. Contractor
    custom_data:     {} of String => String,
    password_length: 6,
    debug:           false,
    test_mode:       false,
  })

  @basic_auth : String = ""
  @portal_id : String = ""
  @sms_service_provider : String? = nil
  @guest_type : String = "default_guest_type"
  @password_length : Int32 = 6
  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @custom_data = {} of String => String

  TYPE_HEADER = "application/json"
  TIME_FORMAT = "%m/%d/%Y %H:%M"

  def on_load
    on_update
  end

  def on_update
    username = setting?(String, :username)
    password = setting?(String, :password)

    @basic_auth = ["Basic", Base64.strict_encode([username, password].join(":"))].join(" ")

    @debug = setting?(Bool, :debug) || false
    @test_mode = setting?(Bool, :test) || false

    @portal_id = setting?(String, :portal_id) || "portal101"
    @guest_type = setting?(String, :guest_type) || "default_guest_type"
    @sms_service_provider = setting?(String, :sms_service_provider)
    @password_length = setting?(Int32, :password_length) || 6

    time_zone = setting?(String, :timezone).presence
    @timezone = Time::Location.load(time_zone) if time_zone
    @custom_data = setting?(Hash(String, String), :custom_data) || {} of String => String

    logger.debug { "Basic auth details: #{@basic_auth}" } if @debug
  end

  def create_internal_user(
    email : String,
    name : String? = nil,
    first_name : String? = nil,
    last_name : String? = nil,
    description : String? = nil,
    password : String? = nil,
    identity_groups : Array(String) = [] of String
  )
    name ||= email
    password ||= generate_password

    internal_user = Models::InternalUser.from_json(
      {
        name:           name,
        email:          email,
        password:       password,
        firstName:      first_name,
        lastName:       last_name,
        description:    description, # custom_attributes: custom_attributes
        identityGroups: identity_groups.join(","),
      }.to_json)

    logger.debug { "Creating Internal User: #{internal_user.to_json}" } if @debug

    response = post("/internaluser/", body: {"InternalUser" => internal_user}.to_json, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    logger.debug { "Response: #{response.status_code}, #{response.body}" } if @debug

    raise "Failed to create internal user, code #{response.status_code}\n#{response.body}" unless response.success?

    user = get_internal_user_by_name(name)
    user.password = password
    user
  end

  def get_internal_user_by_id(id : String)
    response = get("/internaluser/#{id}", headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    logger.debug { "Response: #{response.status_code}, #{response.body}" } if @debug

    raise "failed to get internal user by id, code #{response.status_code}\n#{response.body}" unless response.success?

    parsed_body = JSON.parse(response.body)
    internal_user = Models::InternalUser.from_json(parsed_body["InternalUser"].to_json)

    internal_user
  end

  def get_internal_user_by_name(name : String)
    response = get("/internaluser/name/#{name}", headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    logger.debug { "Response: #{response.status_code}, #{response.body}" } if @debug

    raise "failed to get internal user by name, code #{response.status_code}\n#{response.body}" unless response.success?

    parsed_body = JSON.parse(response.body)
    internal_user = Models::InternalUser.from_json(parsed_body["InternalUser"].to_json)

    internal_user
  end

  def get_internal_user_by_email(email : String)
    response = get("/internaluser/?filter=email.CONTAINS.#{email}", headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    logger.debug { "Response: #{response.status_code}, #{response.body}" } if @debug

    raise "failed to get internal user by email, code #{response.status_code}\n#{response.body}" unless response.success?

    parsed_body = JSON.parse(response.body)

    resources = parsed_body["SearchResult"].as_h.["resources"].as_a

    raise "returned body has no resources" if resources.empty?

    get_internal_user_by_id(resources.first.as_h.["id"].to_s)
  end

  def update_internal_user_password_by_id(id : String, password : String? = nil)
    password ||= generate_password

    response = put("/internaluser/#{id}", body: {"InternalUser" => {"password" => password}}.to_json, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    raise "failed: #{response.status_code}: #{response.body}" unless response.success?

    JSON.parse(response.body)
  end

  def update_internal_user_password_by_name(name : String, password : String? = nil)
    password ||= generate_password

    response = put("/internaluser/name/#{name}", body: {"InternalUser" => {"password" => password}}.to_json, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    raise "failed: #{response.status_code}: #{response.body}" unless response.success?

    JSON.parse(response.body)
  end

  def update_internal_user_password_by_email(email : String, password : String? = nil)
    password ||= generate_password
    internal_user = get_internal_user_by_email(email)

    update_internal_user_password_by_id(internal_user.id.to_s, password)
  end

  def update_internal_user_identity_groups_by_id(id : String, identity_groups : Array(String))
    internal_user = get_internal_user_by_id(id)

    response = put("/internaluser/#{internal_user.id}", body: {"InternalUser" => {"identityGroups" => identity_groups.join(",")}}.to_json, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    raise "failed to get internal user by email, code #{response.status_code}\n#{response.body}" unless response.success?

    JSON.parse(response.body)
  end

  def update_internal_user_identity_groups_by_name(name : String, identity_groups : Array(String))
    internal_user = get_internal_user_by_name(name)

    update_internal_user_identity_groups_by_id(internal_user.id.to_s, identity_groups)
  end

  def update_internal_user_identity_groups_by_email(email : String, identity_groups : Array(String))
    internal_user = get_internal_user_by_email(email)

    update_internal_user_identity_groups_by_id(internal_user.id.to_s, identity_groups)
  end

  # Todo, when ISE doesn't return 401 for Guest related api calls
  # def create_guest (...)
  #   # sms_service_provider ||= @sms_service_provider
  #   # guest_type ||= @guest_type
  #   # portal_id ||= @portal_id

  #   # time_object = Time.unix(event_start).in(@timezone)
  #   # from_date = time_object.at_beginning_of_day.to_s(TIME_FORMAT)
  #   # to_date = time_object.at_end_of_day.to_s(TIME_FORMAT)

  #   # If company_name isn't passed
  #   # Hackily grab a company name from the attendee's email (we may be able to grab this from the signal if possible)
  #   # company_name ||= attendee_email.split('@')[1].split('.')[0].capitalize

  # These custom attributes and any custom attribute needs to be predefined
  # in the ISE GUI.
  # custom_attributes = {
  #   "fromDate"           => from_date,
  #   "toDate"             => to_date,
  #   "location"           => @location.to_s,
  #   "companyName"        => company_name,
  #   "phoneNumber"        => phone_number,
  #   "smsServiceProvider" => sms_service_provider.to_s,
  #   "guestType"          => guest_type,
  #   "portalId"           => portal_id,
  # } of String => String

  # custom_attributes.merge!(@custom_data)
  # end

  # Will be lowercase letters and numbers
  private def generate_password(length : Int32 = @password_length)
    length ||= @password_length
    Random::Secure.base64(length)
  end
end
