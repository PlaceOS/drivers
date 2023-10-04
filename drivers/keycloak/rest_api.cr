require "placeos-driver"
require "link-header"

class Keycloak::RestAPI < PlaceOS::Driver
  # Discovery Information
  generic_name :Keycloak
  descriptive_name "Keycloak service"
  uri_base "https://keycloak.domain.com"

  description %(uses users OAuth2 tokens provided during SSO to access keycloak APIs)

  default_settings({
    place_domain:  "https://placeos.org.com",
    place_api_key: "requires users scope",
    realm:         "realm-id",
  })

  @realm : String = ""
  @api_key : String = ""
  @place_domain : String = ""

  def on_load
    on_update
  end

  def on_update
    @realm = setting(String, :realm) || ""
    @api_key = setting(String, :place_api_key) || ""
    @place_domain = setting(String, :place_domain) || ""
  end

  struct Role
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : String?
    getter name : String?
    getter description : String?
  end

  struct UserDetails
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : String?
    getter username : String?
    getter enabled : Bool?
    getter email : String?

    @[JSON::Field(key: "firstName")]
    getter first_name : String?

    @[JSON::Field(key: "lastName")]
    getter last_name : String?

    @[JSON::Field(key: "realmRoles")]
    getter realm_roles : Array(String)?

    @[JSON::Field(key: "clientRoles")]
    getter client_roles : Array(Role)?

    @[JSON::Field(key: "applicationRoles")]
    getter application_roles : Array(Role)?
    getter groups : Array(String)?
  end

  def users(
    search : String? = nil,
    email : String? = nil,
    enabled_users_only : Bool = true,
    all_pages : Bool = false,
    auth_token : String? = nil
  )
    user_token = "Bearer #{auth_token.presence || get_token}"

    params = URI::Params.build do |form|
      form.add "search", search.to_s if search.presence
      form.add "email", email.to_s if email.presence
      form.add "enabled", enabled_users_only.to_s
      form.add "exact", (!!email.presence).to_s

      # yes it starts at index 1?
      # https://github.com/keycloak/keycloak-community/blob/main/design/rest-api-guideline.md#pagination
      form.add "first", "1"
      form.add "max", "100"
    end

    # Get the existing bookings from the API to check if there is space
    users = [] of UserDetails
    next_request = "/admin/realms/#{@realm}/users?#{params}"
    headers = HTTP::Headers{
      "Accept"        => "application/json",
      "Authorization" => user_token,
    }

    logger.debug { "requesting users, all pages: #{all_pages}" }
    page_count = 1

    loop do
      response = get(next_request, headers: headers)
      raise "unexpected error: #{response.status_code} - #{response.body}" unless response.success?

      links = LinkHeader.new(response)
      next_request = links["next"]?

      new_users = Array(UserDetails).from_json response.body
      users.concat new_users
      break if !all_pages || next_request.nil? || new_users.empty?
      page_count += 1
    end

    logger.debug { "users count: #{users.size}, pages: #{page_count}" }

    users
  end

  def get_token
    user_id = invoked_by_user_id
    raise "only supports requests directly from SSO users" unless user_id
    get_user_token user_id
  end

  @[Security(Level::Administrator)]
  def get_user_token(user_id : String) : String
    response = ::HTTP::Client.post("#{@place_domain}/api/engine/v2/users/#{user_id}/resource_token", headers: HTTP::Headers{
      "X-API-Key" => @api_key,
    })
    raise "failed to obtain a keycloak API key for user #{user_id}: #{response.status_code} - #{response.body}" unless response.success?
    JSON.parse(response.body)["token"].as_s
  end
end
