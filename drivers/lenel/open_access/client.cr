require "responsible"
require "uri"
require "inactive-support/macro/args"
require "./models"

# Lenel OpenAccess API wrapper.
#
# Provides thin abstractions over API endpoints. Requests are executed on the
# pased transport. This can be a `PlaceOS::Driver`, `HTTP::Client` or other type
# supporting the same set of base HTTP request methods.
class Lenel::OpenAccess::Client(Transport)
  private getter transport : Transport

  private getter headers = HTTP::Headers.new

  # URI encodes a set of params.
  #
  # nil values are dropped, and others converted to a String.
  private def encode(named_tuple : NamedTuple) : Hash(String, String)
    params = {} of String => String
    named_tuple.each do |key, value|
      next if value.nil?
      params[key.to_s] = URI.encode_www_form value.to_s
    end
    params
  end

  # :ditto:
  private def encode(**params)
    encode params
  end

  def initialize(@transport : Transport, app_id : String)
    headers["Application-Id"] = app_id
    headers["Content-Type"] = "application/json"
  end

  # Sets the auth token to use on subsequent API requests.
  def token=(token : String)
    headers["Session-Token"] = token
  end

  # Clears the curently set auth token.
  def token=(token : Nil)
    headers.delete "Session-Token"
  end

  def token
    headers["Session-Token"]?
  end

  # Gets the version of the attached OnGuard system.
  def version
    ~transport.get(
      path: "/version",
      params: encode(version: "1.0"),
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
      path: "/authentication",
      headers: headers,
      params: encode(version: "1.0"),
      body: args.to_json,
    ) >> NamedTuple(
      session_token: String,
      token_expiration_time: Time,
    )
  end

  # Removes an auth session.
  def delete_authentication : Nil
    ~transport.delete(
      path: "/authentication",
      params: encode(version: "1.0"),
      headers: headers,
    )
  end

  # Creates a new entry for *instance*.
  def create_instance(instance : T) forall T
    ~transport.post(
      path: "/instances",
      headers: headers,
      params: encode(version: "1.0"),
    ) >> T
  end

  # Retrieves instances of a particular type base on the passed filter.
  #
  # This can be used to query or enumerate records kept on the Lenel system.
  def get_instances(
    type_name type : T.class,
    filter : String? = nil,
    page_number : Int32? = nil,
    page_size : Int32? = nil,
    order_by : String? = nil,
  ) forall T
    ~transport.get(
      path: "/instances",
      headers: headers,
      params: encode args.merge(type_name: T.name, version: "1.0"),
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
