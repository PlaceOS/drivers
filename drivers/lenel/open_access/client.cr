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
      req.headers["Content-Type"]   = "application/json"
      req.headers["Session-Token"]  = token.not_nil! unless token.nil?
    end
  end


  #######
  # Error handling

  Responsible.on_server_error do |response|
    raise OpenAccess::Error.from_response response
  end

  Responsible.on_client_error do |response|
    raise OpenAccess::Error.from_response response
  end


  ########
  # Systen metadata

  # Gets the version of the attached OnGuard system.
  def version
    ~transport.get(
      path: "/version?version=1.0",
    ) >> NamedTuple(
      product_name: String,
      product_version: String,
    )
  end


  ########
  # Auth

  # Enumerates the directories available for auth.
  def get_directories
    (~transport.get(
      path: "/directories?version=1.0",
    ) >> NamedTuple(
      total_items: Int32,
      item_list: Array(NamedTuple(
        property_value_map: {
          ID: String,
          Name: String,
          directory_type: Int32,
        }
      )),
    ))[:item_list].map { |item| item[:property_value_map] }
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


  ########
  # CRUD ops for system info

  # Creates a new entry of *type*.
  def add_instance(type type_name : T.class, **property_value_map : **U) : T forall T, U
    Models.subset T, U
    (~transport.post(
      path: "/instances?version=1.0",
      body: args.to_json
    ) >> NamedTuple(
      type_name: String,
      property_value_map: T,
    ))[:property_value_map]
  end

  # Creates *instance*.
  def add_instance(instance : T) : T forall T
    add_instance T, **instance.to_named_tuple
  end

  # Retrieves instances of a particular *type*.
  #
  # The search criteria specified in *filter* is a subset of SQL. This supports
  # operations such as as:
  # + exclusion `LastName != "Lake"`
  # + wildcards `LastName like "La%"`
  # + boolean operators `LastName = "Lake" OR FirstName = "Lisa"`
  def get_instances(
    type type_name : T.class,
    filter : String? = nil,
    page_number : Int32? = nil,
    page_size : Int32? = nil,
    order_by : String? = nil,
  ) : Array(T) forall T
    params = HTTP::Params.new
    args.merge(type_name: T.name).each do |key, val|
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
      item_list: Array(NamedTuple(type_name: String, property_value_map: T)),
    ))[:item_list].map { |item| item[:property_value_map] }
  end

  # Counts the number of instances of *type*.
  #
  # *filter* may optionally be used to specify a subset of these.
  def get_count(type type_name : T.class, filter : String? = nil) forall T
    params = HTTP::Params.encode args.merge type_name: T.name
    (~transport.get(
      path: "/count?version=1.0&#{params}"
    ) >> NamedTuple(
      total_items: Int32
    ))[:total_items]
  end

  # Updates a record of *type*. Passed properties must include the types key and
  # any fields to update.
  def modify_instance(type type_name : T.class, **property_value_map : **U) : T forall T, U
    Models.subset T, U
    (~transport.put(
      path: "/instances?version=1.0",
      body: args.to_json
    ) >> NamedTuple(
      type_name: String,
      property_value_map: T,
    ))[:property_value_map]
  end

  # Updates an entry to match the data in *instance*.
  def modify_instance(instance : T) : T forall T
    modify_instance T, **instance.to_named_tuple
  end

  # Deletes an instance of *type*.
  def delete_instance(type type_name : T.class, **property_value_map : **U) : Nil forall T, U
    Models.subset T, U
    ~transport.delete(
      path: "/instances?version=1.0",
      body: args.to_json,
    )
  end

  # Deletes *instance*.
  def delete_instance(instance : T) : Nil forall T
    delete_instance T, **instance.to_named_tuple
  end
end
