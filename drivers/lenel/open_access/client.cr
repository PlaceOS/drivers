require "http/client"
require "http/params"
require "responsible"
require "uri"
require "inactive-support/macro/args"

require "./models"
require "./error"

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
      req.headers["Content-Type"] = "application/json"
      req.headers["Session-Token"] = token.not_nil! unless token.nil?
    end
  end

  Responsible.on_server_error do |response|
    raise OpenAccess::Error.from_response response
  end

  Responsible.on_client_error do |response|
    raise OpenAccess::Error.from_response response
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

  # Enumerates the directories available for auth.
  def directories
    (~transport.get(
      path: "/directories?version=1.0"
    ) >> NamedTuple(
      total_items: Int32,
      item_list: Array({property_value_map: {ID: String, Name: String, directory_type: Int32}}),
    ))[:item_list].map { |item| item[:property_value_map] }
  end

  # Creates a new auth session.
  def login(
    username user_name : String,
    password : String,
    directory_id : String?
  )
    ~transport.post(
      path: "/authentication?version=1.0",
      body: args.to_h.compact.to_json,
    ) >> NamedTuple(
      session_token: String,
      token_expiration_time: Time,
    )
  end

  # Removes an auth session.
  def logout : Nil
    ~transport.delete(
      path: "/authentication?version=1.0",
    )
  end

  # Request a connection keepalive to prevent session timeout.
  def keepalive : Nil
    ~transport.get(
      path: "/keepalive?version=1.0",
    )
  end

  # Creates a new instance of *entity*.
  #
  # API create responses return a partial object, which is provided here as an
  # untyped return. This includes the object's database key (which varies
  # between object types - ID, BADGEKEY etc), however contents of this is
  # unspecified. The partial object is provided here, in full, with keys
  # transformed to match how they appear in a type-safe model.
  def create(entity : T.class, **props) forall T
    ~transport.post(
      path: "/instances?version=1.0",
      body: {
        type_name:          T.type_name,
        property_value_map: T.partial(**props),
      }.to_json
    ) >> Models::Untyped
  end

  # Retrieves instances of a particular *entity*.
  #
  # The search criteria specified in *filter* is a subset of SQL. This supports
  # operations such as as:
  # + exclusion `LastName != "Lake"`
  # + wildcards `LastName like "La%"`
  # + boolean operators `LastName = "Lake" OR FirstName = "Lisa"`
  def lookup(
    entity type_name : T.class,
    filter : String? = nil,
    page_number : Int32? = nil,
    page_size : Int32? = nil,
    order_by : String? = nil
  ) : Array(T) forall T
    params = HTTP::Params.new
    args.merge(type_name: T.type_name).each do |key, val|
      params.add key.to_s, val unless val.nil?
    end
    (~transport.get(
      path: "/instances?version=1.0&#{params}",
    ) >> NamedTuple(
      page_number: Int32?,
      page_size: Int32?,
      total_pages: Int32,
      total_items: Int32,
      count: Int32,
      item_list: Array(T),
    ))[:item_list]
  end

  # Counts the number of instances of *entity*.
  #
  # *filter* may optionally be used to specify a subset of these.
  def count(entity type_name : T.class, filter : String? = nil) forall T
    params = HTTP::Params.encode args.merge type_name: T.type_name
    (~transport.get(
      path: "/count?version=1.0&#{params}"
    ) >> NamedTuple(total_items: Int32))[:total_items]
  end

  # Updates a record of *entity*. Passed properties must include the types key and
  # any fields to update.
  def update(entity : T.class, **props) : T forall T
    ~transport.put(
      path: "/instances?version=1.0",
      body: {
        type_name:          T.type_name,
        property_value_map: T.partial(**props),
      }.to_json
    ) >> T
  end

  # Deletes an instance of *entity*.
  def delete(entity : T.class, **props) : Nil forall T
    ~transport.delete(
      path: "/instances?version=1.0",
      body: {
        type_name:          T.type_name,
        property_value_map: T.partial(**props),
      }.to_json
    )
  end
end
