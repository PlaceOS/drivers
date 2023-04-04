require "placeos-driver"
require "oauth2"
require "./vecos/*"

# documentation: https://acc-sapi.releezme.net/swagger/ui/index

class Releezme::Vecos < PlaceOS::Driver
  descriptive_name "Releezme Vecos Gateway"
  generic_name :VecosLockers
  uri_base "https://acc-sapi.releezme.net"

  default_settings({
    client_id:     "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    client_secret: "856b5b85d3eb4697369",
    username:      "admin",
    password:      "admin",
  })

  def on_load
    on_update
  end

  def on_update
    client_id = setting(String, :client_id)
    client_secret = setting(String, :client_secret)
    username = setting(String, :username)
    password = setting(String, :password)

    transport.before_request do |req|
      access_token = get_access_token(client_id, client_secret, username, password)
      req.headers["Authorization"] = access_token
      req.headers["Content-Type"] = "application/json"
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  @expires : Time = Time.utc
  @bearer_token : String = ""
  @access_token : OAuth2::AccessToken? = nil

  protected def get_access_token(client_id, client_secret, username, password)
    return @bearer_token if 1.minute.from_now < @expires

    # check if we are running a spec
    if config.uri.as(String).includes?("127.0.0.1")
      uri = URI.parse config.uri.as(String)
      auth_domain = uri.host.as(String)
      port = uri.port.as(Int32)
      scheme = "http"
    else
      auth_domain = "acc-identity.releezme.net"
      scheme = "https"
    end

    # use the built in crystal oauth client
    client = OAuth2::Client.new(auth_domain, client_id, client_secret, scheme: scheme, port: port, token_uri: "/connect/token")
    token = if (access_token = @access_token) && access_token.refresh_token.presence
              begin
                client.get_access_token_using_refresh_token(access_token.refresh_token)
              rescue error : OAuth2::Error
                logger.warn(exception: error) { "failed to refresh token" }
                client.get_access_token_using_resource_owner_credentials(username: username, password: password, scope: "Vecos.Releezme.Web.SAPI offline_access")
              end
            else
              client.get_access_token_using_resource_owner_credentials(username: username, password: password, scope: "Vecos.Releezme.Web.SAPI offline_access")
            end
    @expires = token.expires_in.as(Int64).seconds.from_now
    @access_token = token
    @bearer_token = "Bearer #{token.access_token}"
  end

  @[Security(Level::Support)]
  def fetch_pages(location : String) : Array(JSON::Any)
    append = location.includes?('?') ? '&' : '?'
    next_page = "#{location}#{append}pageNumber=#{1}"
    data = [] of JSON::Any

    loop do
      response = get(next_page)
      @expires = 1.minute.ago if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      payload = JSON.parse(response.body).as_h
      pages = if has_paging = payload.delete("Paging")
                Paging.from_json has_paging.to_json
              end
      data.concat payload[payload.keys.first].as_a

      break unless pages && pages.has_next_page

      next_page = "#{location}#{append}pageNumber=#{pages.page_number + 1}"
    end

    data
  end

  @[Security(Level::Support)]
  def fetch_item(location : String) : String
    response = get(location)
    @expires = 1.minute.ago if response.status_code == 401
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }
    response.body
  end

  def companies
    JSON.parse(fetch_item("/api/companies"))["Companies"]
  end

  # typically these are buildings
  def locations
    Array(Location).from_json fetch_pages("/api/locations?pageSize=200").to_json
  end

  # typically these are floors in the building
  def sections(location_id : String)
    Array(Section).from_json fetch_pages("/api/locations/#{location_id}/sections?pageSize=200").to_json
  end

  # the lockers that are currently allocated to the specified user
  # the user ID is typically email - defined by the client
  def lockers_allocated_to(user_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
      form.add "pageSize", "200"
    end
    Array(Locker).from_json fetch_pages("/api/lockers/allocated?#{params}").to_json
  end

  # check if a user can be allocated a new locker
  def can_allocate_locker?(user_id : String) : String
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
    end
    response = get("/api/lockers/canallocate?#{params}")
    response.body
  end
end
