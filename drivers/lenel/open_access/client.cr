require "http/client"
require "http/params"
require "responsible"
require "uri"
require "inactive-support/macro/args"
require "./models"

# Lenel OpenAccess API wrapper.
#
# Provides thin abstractions over API endpoints. Requests are executed on the
# pased transport. This can be a `PlaceOS::Driver`, `HTTP::Client` or other type
# supporting the same set of base HTTP request methods.
class Lenel::OpenAccess::Client
  private getter transport : HTTP::Client

  property app_id : String

  property token : String?

  def initialize(@transport, @app_id)
    transport.before_request do |req|
      req.headers["Application-Id"] = app_id
      req.headers["Content-Type"]   = "application/json"
      req.headers["Session-Token"]  = token.not_nil! unless token.nil?
    end
  end

  # Gets the version of the attached OnGuard system.
  def version
    ~transport.get(
      path: "/version?version=1.0",
    ) >> NamedTuple(
      product_name: String,
      product_version: String,
    )
  end

  # Creates a new auth session.
  def add_authentication(
    username user_name : String,
    password : String,
    directory_id : String,
  )
    ~transport.post(
      path: "/authentication?version=1.0",
      body: args.to_json,
    ) >> NamedTuple(
      session_token: String,
      token_expiration_time: Time,
    )
  end

  # Removes an auth session.
  def delete_authentication : Nil
    ~transport.delete(
      path: "/authentication?version=1.0",
    )
  end

  # Creates a new entry for *instance*.
  def create_instance(instance : T) forall T
    ~transport.post(
      path: "/instances?version=1.0",
    ) >> T
  end

  # Retrieves instances of a particular type base on the passed filter.
  #
  # This can be used to query or enumerate records kept on the Lenel system.
  def get_instances(
    type type_name : T.class,
    filter : String? = nil,
    page_number : Int32? = nil,
    page_size : Int32? = nil,
    order_by : String? = nil,
  ) forall T
    params = HTTP::Params.encode args.merge type_name: T.name
    ~transport.get(
      path: "/instances?version=1.0&#{params}",
    ) >> NamedTuple(
      page_number: Int32?,
      page_size: Int32?,
      total_pages: Int32,
      total_items: Int32,
      count: Int32,
      item_list: Array(T),
      type_name: String,
      property_value_map: Hash(String, String),
    )
  end
end
