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
  uri_base "https://api.origo.hidglobal.com"
  description "HID Origo REST API driver for user management and credential management"

  CRED_DOMAIN = "https://credential-management.api.origo.hidglobal.com/"

  default_settings({
    organization_id: "123456",
    client_id:       "your_client_id",
    client_secret:   "your_client_secret",
    application_id:  "HID-PLACEOS-DRIVER",
  })

  @organization_id : String = ""
  @client_id : String = ""
  @client_secret : String = ""
  @application_id : String = ""
  @access_token : String = ""
  @token_expires : Time = Time.utc
  @cred_domain : String = CRED_DOMAIN

  def on_load
    on_update
  end

  def on_update
    @organization_id = setting?(String, :organization_id) || ""
    @client_id = setting?(String, :client_id) || ""
    @client_secret = setting?(String, :client_secret) || ""
    @application_id = setting?(String, :application_id) || "HID-PLACEOS-DRIVER"

    # check if we are running specs
    default_uri = config.uri.as(String)
    @cred_domain = default_uri.includes?("127.0.0.1") ? default_uri.rchop("/") + "/" : CRED_DOMAIN
  end

  private def ensure_authenticated
    return if !@access_token.empty? && @token_expires > Time.utc

    token_request = TokenRequest.new(@client_id, @client_secret)

    response = post("/authentication/customer/#{@organization_id}/token",
      body: token_request.to_json,
      headers: {
        "Content-Type"        => "application/json",
        "Accept"              => "application/json",
        "Application-ID"      => @application_id,
        "Application-Version" => "1.0",
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
      raise "Authentication failed with status #{response.status_code}"
    end
  end

  private def auth_headers
    ensure_authenticated
    {
      "Authorization"       => "Bearer #{@access_token}",
      "Application-ID"      => @application_id,
      "Application-Version" => "1.0",
      "Content-Type"        => "application/scim+json",
      "Accept"              => "application/scim+json",
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

  # User Management API methods
  def list_users(start_index : Int32 = 0, count : Int32 = 20) : PaginatedUserList
    response = get("/scim/organization/#{@organization_id}/users",
      headers: auth_headers,
      params: {
        "startIndex" => start_index.to_s,
        "count"      => count.to_s,
      }
    )

    if response.status_code == 200
      PaginatedUserList.from_json(response.body)
    else
      raise "Failed to list users: #{response.status_code}"
    end
  end

  def get_user(user_id : String) : User
    response = get("/scim/organization/#{@organization_id}/users/#{user_id}",
      headers: auth_headers
    )

    if response.status_code == 200
      User.from_json(response.body)
    else
      raise "Failed to get user: #{response.status_code}"
    end
  end

  def create_user(user : User) : User
    response = post("/scim/organization/#{@organization_id}/users",
      body: user.to_json,
      headers: auth_headers
    )

    if response.status_code == 201
      User.from_json(response.body)
    else
      raise "Failed to create user: #{response.status_code}"
    end
  end

  def update_user(user_id : String, user : User) : User
    response = put("/scim/organization/#{@organization_id}/users/#{user_id}",
      body: user.to_json,
      headers: auth_headers
    )

    if response.status_code == 200
      User.from_json(response.body)
    else
      raise "Failed to update user: #{response.status_code}"
    end
  end

  def delete_user(user_id : String) : Bool
    response = delete("/scim/organization/#{@organization_id}/users/#{user_id}",
      headers: auth_headers
    )

    if response.status_code == 204
      true
    else
      raise "Failed to delete user: #{response.status_code}"
    end
  end

  def search_users(filter : String, start_index : Int32 = 0, count : Int32 = 20) : PaginatedUserList
    search_request = UserSearchRequest.new(filter, start_index, count)

    response = post("/scim/organization/#{@organization_id}/users/.search",
      body: search_request.to_json,
      headers: auth_headers
    )

    if response.status_code == 200
      PaginatedUserList.from_json(response.body)
    else
      raise "Failed to search users: #{response.status_code}"
    end
  end

  # Credential Management API methods
  def list_passes : PassCollection
    ensure_authenticated

    headers = HTTP::Headers.new
    headers["Authorization"] = "Bearer #{@access_token}"
    headers["Application-ID"] = @application_id
    headers["Application-Version"] = "1.0"
    headers["Content-Type"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"
    headers["Accept"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"

    begin
      response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass", headers: headers)

      if response.status_code == 200
        PassCollection.from_json(response.body)
      else
        raise "Failed to list passes: #{response.status_code}"
      end
    rescue ex
      raise "Error listing passes: #{ex.message}"
    end
  end

  def get_pass(pass_id : String) : PassDetails
    ensure_authenticated

    headers = HTTP::Headers.new
    headers["Authorization"] = "Bearer #{@access_token}"
    headers["Application-ID"] = @application_id
    headers["Application-Version"] = "1.0"
    headers["Content-Type"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"
    headers["Accept"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"

    begin
      response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}", headers: headers)

      if response.status_code == 200
        PassDetails.from_json(response.body)
      else
        raise "Failed to get pass: #{response.status_code}"
      end
    rescue ex
      raise "Error getting pass: #{ex.message}"
    end
  end

  def create_pass(pass_request : CreatePassRequest) : PassDetails
    ensure_authenticated

    headers = HTTP::Headers.new
    headers["Authorization"] = "Bearer #{@access_token}"
    headers["Application-ID"] = @application_id
    headers["Application-Version"] = "1.0"
    headers["Content-Type"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"
    headers["Accept"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"

    begin
      response = HTTP::Client.post("#{@cred_domain}organization/#{@organization_id}/pass",
        body: pass_request.to_json,
        headers: headers
      )

      if response.status_code == 201
        PassDetails.from_json(response.body)
      else
        raise "Failed to create pass: #{response.status_code}"
      end
    rescue ex
      raise "Error creating pass: #{ex.message}"
    end
  end

  def update_pass(pass_id : String, pass_request : UpdatePassRequest) : PassDetails
    ensure_authenticated

    headers = HTTP::Headers.new
    headers["Authorization"] = "Bearer #{@access_token}"
    headers["Application-ID"] = @application_id
    headers["Application-Version"] = "1.0"
    headers["Content-Type"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"
    headers["Accept"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"

    begin
      response = HTTP::Client.put("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}",
        body: pass_request.to_json,
        headers: headers
      )

      if response.status_code == 200
        PassDetails.from_json(response.body)
      else
        raise "Failed to update pass: #{response.status_code}"
      end
    rescue ex
      raise "Error updating pass: #{ex.message}"
    end
  end

  def delete_pass(pass_id : String) : Bool
    ensure_authenticated

    headers = HTTP::Headers.new
    headers["Authorization"] = "Bearer #{@access_token}"
    headers["Application-ID"] = @application_id
    headers["Application-Version"] = "1.0"
    headers["Content-Type"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"
    headers["Accept"] = "application/vnd.hidglobal.origo.credential-management-3.0+json"

    begin
      response = HTTP::Client.delete("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}", headers: headers)

      if response.status_code == 204
        true
      else
        raise "Failed to delete pass: #{response.status_code}"
      end
    rescue ex
      raise "Error deleting pass: #{ex.message}"
    end
  end

  # Convenience methods for creating common user structures
  def create_basic_user(user_name : String, display_name : String, email : String, active : Bool = true) : User
    user = User.new(user_name, display_name, active)
    user.emails = [Email.from_json({"value" => email, "primary" => true}.to_json)]
    create_user(user)
  end

  def create_basic_pass(user_id : String, status : String = "active") : PassDetails
    pass_request = CreatePassRequest.new(user_id, status)
    create_pass(pass_request)
  end

  def suspend_pass(pass_id : String) : PassDetails
    update_request = UpdatePassRequest.new("suspended")
    update_pass(pass_id, update_request)
  end

  def activate_pass(pass_id : String) : PassDetails
    update_request = UpdatePassRequest.new("active")
    update_pass(pass_id, update_request)
  end
end
