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
  @cred_domain : String = CRED_DOMAIN

  def on_load
    on_update
  end

  def on_update
    @client_id = setting?(String, :client_id) || ""
    @client_secret = setting?(String, :client_secret) || ""
    @application_id = setting?(String, :application_id) || "HID-PLACEOS-DRIVER"
    @application_ver = setting?(String, :application_ver) || "1.0"
    @organization_id = @client_id.split('-', 2).first

    # check if we are running specs
    default_uri = config.uri.as(String)
    @cred_domain = default_uri.includes?("127.0.0.1") ? default_uri.rchop("/") + "/" : CRED_DOMAIN
  end

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
      raise "Authentication failed with status #{response.status_code}"
    end
  end

  private def auth_headers
    ensure_authenticated
    {
      "Authorization"       => "Bearer #{@access_token}",
      "Application-ID"      => @application_id,
      "Application-Version" => @application_ver,
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

    raise "Failed to list users: #{response.status_code}\n#{response.body}" unless response.success?
    PaginatedUserList.from_json(response.body)
  end

  def get_user(user_id : String) : User
    response = get("/scim/organization/#{@organization_id}/users/#{user_id}",
      headers: auth_headers
    )

    raise "Failed to get user: #{response.status_code}\n#{response.body}" unless response.success?
    User.from_json(response.body)
  end

  def create_user(user : User) : User
    response = post("/scim/organization/#{@organization_id}/users",
      body: user.to_json,
      headers: auth_headers
    )

    raise "Failed to create user: #{response.status_code}\n#{response.body}" unless response.success?
    User.from_json(response.body)
  end

  def update_user(user_id : String, user : User) : User
    response = put("/scim/organization/#{@organization_id}/users/#{user_id}",
      body: user.to_json,
      headers: auth_headers
    )

    raise "Failed to update user: #{response.status_code}\n#{response.body}" unless response.success?
    User.from_json(response.body)
  end

  def delete_user(user_id : String) : Bool
    response = delete("/scim/organization/#{@organization_id}/users/#{user_id}",
      headers: auth_headers
    )

    raise "Failed to delete user: #{response.status_code}\n#{response.body}" unless response.success?
    true
  end

  def search_users(filter : String, start_index : Int32 = 0, count : Int32 = 20) : PaginatedUserList
    search_request = UserSearchRequest.new(filter, start_index, count)

    response = post("/scim/organization/#{@organization_id}/users/.search",
      body: search_request.to_json,
      headers: auth_headers
    )

    raise "Failed to search users: #{response.status_code}\n#{response.body}" unless response.success?
    PaginatedUserList.from_json(response.body)
  end

  # Credential Management API methods
  private def credential_headers
    ensure_authenticated
    HTTP::Headers{
      "Authorization"       => "Bearer #{@access_token}",
      "Application-ID"      => @application_id,
      "Application-Version" => @application_ver,
      "Content-Type"        => "application/vnd.hidglobal.origo.credential-management-3.0+json",
      "Accept"              => "application/vnd.hidglobal.origo.credential-management-3.0+json",
    }
  end

  def list_passes : PassCollection
    response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass", headers: credential_headers)
    raise "Failed to list passes: #{response.status_code}\n#{response.body}" unless response.success?
    PassCollection.from_json(response.body)
  end

  def get_pass(pass_id : String) : Pass
    response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}", headers: credential_headers)
    raise "Failed to get pass: #{response.status_code}\n#{response.body}" unless response.success?
    Pass.from_json(response.body)
  end

  def create_pass(user_id : String, pass_template_id : String) : Pass
    pass_request = Pass.new(user_id, pass_template_id)

    response = HTTP::Client.post("#{@cred_domain}organization/#{@organization_id}/pass",
      body: pass_request.to_json,
      headers: credential_headers
    )
    raise "Failed to create pass: #{response.status_code}\n#{response.body}" unless response.success?
    Pass.from_json(response.body)
  end

  def update_pass(pass_id : String, status : PassStatus) : Pass
    pass_request = Pass.new(status.to_s.underscore.upcase)
    response = HTTP::Client.put("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}",
      body: pass_request.to_json,
      headers: credential_headers
    )
    raise "Failed to update pass: #{response.status_code}\n#{response.body}" unless response.success?
    Pass.from_json(response.body)
  end

  def delete_pass(pass_id : String) : Bool
    response = HTTP::Client.delete("#{@cred_domain}organization/#{@organization_id}/pass/#{pass_id}", headers: credential_headers)
    raise "Failed to delete pass: #{response.status_code}\n#{response.body}" unless response.success?
    true
  end

  # Convenience methods for creating common user structures
  def create_basic_user(user_name : String, display_name : String, email : String, active : Bool = true) : User
    user = User.new(user_name, display_name, active)
    user.emails = [Email.from_json({"value" => email, "primary" => true}.to_json)]
    create_user(user)
  end

  def suspend_pass(pass_id : String) : Pass
    update_pass(pass_id, PassStatus::Suspended)
  end

  def activate_pass(pass_id : String) : Pass
    update_pass(pass_id, PassStatus::Active)
  end

  # Pass Template API methods
  def list_pass_templates(page : Int32 = 0, page_size : Int32 = 20) : PassTemplateCollection
    query_params = "?page=#{page}&page-size=#{page_size}"
    response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass-template#{query_params}",
      headers: credential_headers
    )
    raise "Failed to list pass templates: #{response.status_code}\n#{response.body}" unless response.success?
    PassTemplateCollection.from_json(response.body)
  end

  def get_pass_template(pass_template_id : String) : PassTemplate
    response = HTTP::Client.get("#{@cred_domain}organization/#{@organization_id}/pass-template/#{pass_template_id}",
      headers: credential_headers
    )
    raise "Failed to get pass template: #{response.status_code}\n#{response.body}" unless response.success?
    PassTemplate.from_json(response.body)
  end

  def create_pass_template(template : PassTemplate) : PassTemplate
    response = HTTP::Client.post("#{@cred_domain}organization/#{@organization_id}/pass-template",
      body: template.to_json,
      headers: credential_headers
    )
    raise "Failed to create pass template: #{response.status_code}\n#{response.body}" unless response.success?
    PassTemplate.from_json(response.body)
  end

  def update_pass_template(pass_template_id : String, template : PassTemplate) : PassTemplate
    response = HTTP::Client.patch("#{@cred_domain}organization/#{@organization_id}/pass-template/#{pass_template_id}",
      body: template.to_json,
      headers: credential_headers
    )
    raise "Failed to update pass template: #{response.status_code}\n#{response.body}" unless response.success?
    PassTemplate.from_json(response.body)
  end

  def delete_pass_template(pass_template_id : String) : Bool
    response = HTTP::Client.delete("#{@cred_domain}organization/#{@organization_id}/pass-template/#{pass_template_id}",
      headers: credential_headers
    )
    raise "Failed to delete pass template: #{response.status_code}\n#{response.body}" unless response.success?
    true
  end
end
