require "placeos-driver"
require "time"
require "uri"
require "responsible"
require "inactive-support/macro/args"
require "./models"

module Lenel; end

class Lenel::OpenAccess < PlaceOS::Driver
  include Models

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

  # Gets the version of the attached OnGuard system.
  def version : {product_name: String, product_version: String}
    Responsible.parse_to_return_type do
      get("/version", params: {"version" => "1.0"})
    end
  end

  # Gets the auth setting from the DB.
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
  private def token : String
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

  # Provide a set of `HTTP::Header` that satisfies the base requirements for the
  # API.
  #
  # If unspecified a valid auth token will be included (and created if
  # nescessary. Endpoint that do not require auth can pass `nil` as the token
  # param to omit this.
  private def default_headers(token session_token : String? = token)
    HTTP::Headers.new.tap do |headers|
      headers["Session-Token"] = session_token if session_token
      headers["Application-Id"] = @app_id
      headers["Content-Type"] = "application/json"
    end
  end

  # Creates a new auth session.
  private def add_authentication(
    username user_name : String,
    password : String,
    directory_id : String
  )
    ~post("/authentication",
      headers: default_headers(token: nil),
      params: {"version" => "1.0"},
      body: args.to_json
    ) >> NamedTuple(
      session_token: String,
      token_expiration_time: Time
    )
  end

  # Deletes an auth session.
  private def delete_authentication(token : String) : Nil
    ~delete("/authentication",
      params: {"version" => "1.0"}, 
      headers: default_headers token
    )
  end

  # Builds a `Hash` from a `NamedTuple` with all values URI encoded.
  #
  # nil value are dropped, and others converted to a String.
  private def encode(named_tuple : NamedTuple) : Hash(String, String)
    params = {} of String => String
    named_tuple.each do |key, value|
      next if value.nil?
      params[key.to_s] = URI.encode_www_form value.to_s
    end
    params
  end

  # Retrieve all instances of a particular type base on the passed filter.
  #
  # This can be used to query or enumerate records kept on the Lenel system.
  private def get_instances(
    type_name type : T.class,
    filter : String? = nil,
    page_number : Int32? = nil,
    page_size : Int32? = nil,
    order_by : String? = nil
  ) forall T
    ~get("/instances",
      headers: default_headers,
      params: encode args.merge version: "1.0"
    ) >> NamedTuple(
      page_number: Int32?,
      page_size: Int32?,
      total_pages: Int32,
      total_items: Int32,
      count: Int32,
      item_list: Array(T),
      type_name: String,
      property_value_map: Hash(String, String)
    )
  end

  # TODO: remove me, temp for testing
  def get_test
    get_instances Lnl_AccessGroup
  end
end
