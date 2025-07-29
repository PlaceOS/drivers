require "placeos-driver"
require "json"
require "uri"
require "http/client"
require "./origo_rest_api_models"

# Documentation: https://doc.origo.hidglobal.com/api/authentication/
class HID::OrigoRestApi < PlaceOS::Driver
  # Discovery Information
  generic_name :HID
  descriptive_name "HID Origo REST API"

  # only used for authentication
  uri_base "https://api.origo.hidglobal.com"
  description "HID Origo REST API driver for user management and credential management"

  # Based on the authentication domain
  DOMAIN_SELECTION = {
    "https://api.origo.hidglobal.com" => {
      users: "https://ma.api.assaabloy.com",
    },
    "https://api.cert.origo.hidglobal.com" => {
      users: "https://cert.mi.api.origo.hidglobal.com",
    },
  }

  default_settings({
    client_id:       "your_client_id",
    client_secret:   "your_client_secret",
    application_id:  "HID-PLACEOS-DRIVER",
    application_ver: "1.0",
  })

  @organization_id : String = ""
  @client_id : String = ""
  @client_secret : String = ""
  @application_id : String = ""
  @application_ver : String = ""
  @access_token : String = ""
  @token_expires : Time = Time.utc
  @spec_domain : String? = nil
  @auth_domain : String = "https://api.origo.hidglobal.com"

  def on_update
    @client_id = setting?(String, :client_id) || ""
    @client_secret = setting?(String, :client_secret) || ""
    @application_id = setting?(String, :application_id) || "HID-PLACEOS-DRIVER"
    @application_ver = setting?(String, :application_ver) || "1.0"
    @organization_id = @client_id.split('-', 2).first

    # check if we are running specs
    @auth_domain = config.uri.as(String)
    @spec_domain = @auth_domain.includes?("127.0.0.1") ? @auth_domain.rchop("/") : nil
  end

  protected def select_domain(key : Symbol) : String
    @spec_domain || DOMAIN_SELECTION[@auth_domain][key]
  end

  # 3 requests to work:
  # 1. check if a user exists: search_users via email
  # 2. get part numbers: https://doc.origo.hidglobal.com/api/mobile-identities/#/Part%20Number/get-customer-organization_id-part-number
  # 3. invite the user: https://doc.origo.hidglobal.com/api/mobile-identities/#/Invitation/post-customer-organization_id-users-user_id-invitation
  # the mobile app should unsubscribe the mobile credential on logout

  private def ensure_authenticated
    return if !@access_token.empty? && @token_expires > Time.utc

    token_request = URI::Params.build do |form|
      form.add("client_id", @client_id)
      form.add("client_secret", @client_secret)
      form.add("grant_type", "client_credentials")
    end

    response = post("/authentication/customer/#{@organization_id}/token",
      body: token_request,
      headers: {
        "Content-Type"        => "application/x-www-form-urlencoded",
        "Accept"              => "application/json",
        "X-Request-ID"        => @organization_id,
        "Application-ID"      => @application_id,
        "Application-Version" => @application_ver,
      }
    )

    if response.status_code == 200
      token_response = TokenResponse.from_json(response.body)
      @access_token = token_response.access_token
      @token_expires = Time.utc + token_response.expires_in.seconds - 60.seconds # 60 second buffer

      self[:token_expires] = @token_expires.to_s
      self[:authenticated] = true
    else
      @access_token = ""
      @token_expires = Time.utc
      self[:authenticated] = false
      raise "Authentication failed with status #{response.status_code}\n#{response.body}"
    end
  end

  private def auth_headers
    ensure_authenticated
    HTTP::Headers{
      "Authorization"       => "Bearer #{@access_token}",
      "Application-ID"      => @application_id,
      "Application-Version" => @application_ver,
    }
  end

  # Authentication methods
  def login
    ensure_authenticated
    !@access_token.empty?
  end

  def authenticated?
    !@access_token.empty? && @token_expires > Time.utc
  end

  def search_users(email : String, start_index : Int32 = 0, count : Int32 = 20) : PaginatedUserList
    search_request = UserSearchRequest.new("emails eq \"#{email}\"", start_index, count)

    response = HTTP::Client.post("#{select_domain(:user)}/credential-management/customer/#{@organization_id}/users/.search",
      body: search_request.to_json,
      headers: auth_headers
    )

    raise "Failed to search users: #{response.status_code}\n#{response.body}" unless response.success?
    PaginatedUserList.from_json(response.body)
  end

  def get_user(user_id : Int64) : User
    response = HTTP::Client.get("#{select_domain(:user)}/credential-management/customer/#{@organization_id}/users/#{user_id}",
      headers: auth_headers
    )

    raise "Failed to get user: #{response.status_code}\n#{response.body}" unless response.success?
    User.from_json(response.body)
  end
end
