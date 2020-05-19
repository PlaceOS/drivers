require "placeos-driver"
require "time"
require "responsible"
require "inactive-support/macro/args"

module Lenel; end

class Lenel::OpenAccess < PlaceOS::Driver
  generic_name :Security
  descriptive_name "Lenel OpenAccess"
  description "Bindings for Lenel OnGuard physical security system"
  uri_base "https://example.com/api/access/onguard/openaccess"
  default_settings({
    application_id: "",
    directory_id:   "",
    username:       "",
    password:       "",
  })

  @app_id : String = ""
  @token : String?
  @token_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @app_id = setting(String, :application_id)
    expire_session!
  end

  def on_unload
    expire_session!
  end

  # Gets the version of the attached OnGuard system
  def version : {product_name: String, product_version: String}
    Responsible.parse_to_return_type do
      get("/version", params: {"version" => "1.0"})
    end
  end

  private def auth_settings
    username = setting(String, :username)
    password = setting(String, :password)
    directory = setting(String, :directory_id)
    {username, password, directory}
  end

  # Gets a session token that can be used for authenticated methods.
  #
  # Token creation and caching is automatically handled. This method should be
  # used anywhere a token is required and you are not seeking to explicity
  # create a new session.
  private def session_token : String
    return @token.not_nil! unless @token_expiry < Time.utc
    auth = add_authentication *auth_settings
    @token_expiry = auth[:token_expiration_time]
    @token = auth[:session_token]
  end

  # Invalidate the curerntly active auth session.
  private def expire_session! : Nil
    delete_authentication @token.not_nil! unless @token_expiry < Time.utc
  ensure
    @token_expiry = 1.minute.ago
    @token = nil
  end

  # Creates a new auth session.
  private def add_authentication(username user_name : String, password : String, directory_id : String) : {session_token: String, token_expiration_time: Time}
    Responsible.parse_to_return_type do
      post("/authentication",
        params: {"version" => "1.0"},
        headers: {"content-type" => "application/json"},
        body: args.to_json
      )
    end
  end

  # Deletes an auth session.
  private def delete_authentication(token : String) : Nil
    ~delete("/authentication",
      params: {"version" => "1.0", "session-token" => token}
    )
  end
end
