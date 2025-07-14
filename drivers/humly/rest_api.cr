require "placeos-driver"
require "./rest_api_models"

class Humly::RestApi < PlaceOS::Driver
  # Discovery Information
  generic_name :HumlyAPI
  descriptive_name "Humly Control Panel REST API"
  uri_base "https://your-humly-server.com"

  description %(
  Driver for Humly Control Panel REST API integration.
  Requires Humly Control Panel v1.0.x or higher.

  API Documentation: https://raw.githubusercontent.com/CertusOp/humly-control-panel-rest-api/refs/heads/master/README.md

  Settings required:
  - username: Integration user credentials (defaultDevIntegrationUser or Admin)
  - password: User password
)

  default_settings({
    username: "defaultDevIntegrationUser",
    password: "changeme",
  })

  @username : String = ""
  @password : String = ""
  @user_id : String = ""
  @auth_token : String = ""
  @authenticated : Bool = false

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)

    # Clear authentication state on settings update
    @authenticated = false
    @user_id = ""
    @auth_token = ""
  end

  # Authentication
  def login : Bool
    response = post("/api/v1/login",
      body: "username=#{@username}&password=#{@password}",
      headers: {
        "Content-Type" => "application/x-www-form-urlencoded",
      }
    )

    if response.success?
      result = Humly::ApiResponse(Humly::LoginResponse).from_json(response.body)

      if result.status == "success" && result.data
        @user_id = result.data.not_nil!.userId
        @auth_token = result.data.not_nil!.authToken
        @authenticated = true

        self[:user_id] = @user_id
        self[:authenticated] = true

        logger.info { "Successfully authenticated with Humly API" }
      else
        logger.error { "Authentication failed: #{result.message}" }
        @authenticated = false
        self[:authenticated] = false
      end
    else
      logger.error { "Login request failed: #{response.status_code} - #{response.body}" }
      @authenticated = false
      self[:authenticated] = false
    end

    @authenticated
  end

  def ensure_authenticated
    return if @authenticated
    login
  end

  private def authenticated_headers
    {
      "X-User-Id"    => @user_id,
      "X-Auth-Token" => @auth_token,
      "Content-Type" => "application/json",
    }
  end

  private def authenticated_request(method, path, body = nil, query = nil, retry = 0)
    ensure_authenticated
    raise "not authenticated" unless @authenticated

    headers = authenticated_headers

    response = case method.downcase
               when "get"
                 if query
                   get("#{path}?#{query}", headers: headers)
                 else
                   get(path, headers: headers)
                 end
               when "post"
                 post(path, headers: headers, body: body)
               when "patch"
                 patch(path, headers: headers, body: body)
               when "put"
                 put(path, headers: headers, body: body)
               when "delete"
                 delete(path, headers: headers)
               else
                 raise "Unsupported HTTP method: #{method}"
               end

    # retry if unauthorized by logging in
    if response.status.unauthorized?
      @authenticated = false
      self[:authenticated] = false
      return authenticated_request(method, path, body, query, retry + 1) unless retry > 1
    end

    response
  end

  # Client Groups API
  def create_client_group(name : String, description : String? = nil)
    body = {name: name}
    body = body.merge({description: description}) if description

    response = authenticated_request("post", "/api/v1/clientGroups", body.to_json)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Humly::ClientGroup).from_json(response.body)
      if result.status == "success" && result.data
        self[:last_client_group] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to create client group: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to create client group: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Users API
  def get_users(limit : Int32 = 50, offset : Int32 = 0)
    params = "limit=#{limit}&offset=#{offset}"
    response = authenticated_request("get", "/api/v1/users/integration", query: params)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::User)).from_json(response.body)
      if result.status == "success" && result.data
        self[:users] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get users: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get users: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  def create_integration_user(email : String, name : String)
    body = {email: email, name: name}

    response = authenticated_request("post", "/api/v1/users/integration", body.to_json)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Humly::User).from_json(response.body)
      if result.status == "success" && result.data
        self[:last_created_user] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to create integration user: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to create integration user: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Rooms API
  def get_rooms(limit : Int32 = 50, offset : Int32 = 0, sort : String? = nil)
    params = ["limit=#{limit}", "offset=#{offset}"]
    params << "sort=#{sort}" if sort

    response = authenticated_request("get", "/api/v1/rooms", query: params.join("&"))
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Room)).from_json(response.body)
      if result.status == "success" && result.data
        self[:rooms] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get rooms: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get rooms: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Desks API
  def get_desks(limit : Int32 = 50, offset : Int32 = 0, sort : String? = nil)
    params = ["limit=#{limit}", "offset=#{offset}"]
    params << "sort=#{sort}" if sort

    response = authenticated_request("get", "/api/v1/desks", query: params.join("&"))
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Desk)).from_json(response.body)
      if result.status == "success" && result.data
        self[:desks] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get desks: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get desks: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Bookings API
  def get_bookings(limit : Int32 = 50, offset : Int32 = 0, sort : String? = nil)
    params = ["limit=#{limit}", "offset=#{offset}"]
    params << "sort=#{sort}" if sort

    response = authenticated_request("get", "/api/v1/bookings", query: params.join("&"))
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Booking)).from_json(response.body)
      if result.status == "success" && result.data
        self[:bookings] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get bookings: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get bookings: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  def create_booking(start_time : String, end_time : String, resource_id : String, title : String? = nil, description : String? = nil)
    body = {
      startTime:  start_time,
      endTime:    end_time,
      resourceId: resource_id,
    }
    body = body.merge({title: title}) if title
    body = body.merge({description: description}) if description

    response = authenticated_request("post", "/api/v1/bookings", body.to_json)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Humly::Booking).from_json(response.body)
      if result.status == "success" && result.data
        self[:last_booking] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to create booking: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to create booking: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  def update_booking(booking_id : String, start_time : String? = nil, end_time : String? = nil, title : String? = nil, description : String? = nil)
    body = {} of String => String
    body["startTime"] = start_time if start_time
    body["endTime"] = end_time if end_time
    body["title"] = title if title
    body["description"] = description if description

    response = authenticated_request("patch", "/api/v1/bookings/#{booking_id}", body.to_json)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Humly::Booking).from_json(response.body)
      if result.status == "success" && result.data
        self[:updated_booking] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to update booking: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to update booking: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  def delete_booking(booking_id : String)
    response = authenticated_request("delete", "/api/v1/bookings/#{booking_id}")
    return unless response

    if response.success?
      logger.info { "Successfully deleted booking #{booking_id}" }
      self[:last_deleted_booking] = booking_id
      true
    else
      logger.error { "Failed to delete booking: #{response.status_code} - #{response.body}" }
      false
    end
  end

  def checkin_booking(booking_id : String)
    body = {bookingId: booking_id}

    response = authenticated_request("put", "/api/v1/bookings/checkedIn", body.to_json)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Humly::Booking).from_json(response.body)
      if result.status == "success" && result.data
        self[:checked_in_booking] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to check in booking: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to check in booking: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Structures API
  def get_structures(limit : Int32 = 50, offset : Int32 = 0)
    params = "limit=#{limit}&offset=#{offset}"
    response = authenticated_request("get", "/api/v1/structures", query: params)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Country)).from_json(response.body)
      if result.status == "success" && result.data
        self[:structures] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get structures: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get structures: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Devices API
  def get_devices(limit : Int32 = 50, offset : Int32 = 0)
    params = "limit=#{limit}&offset=#{offset}"
    response = authenticated_request("get", "/api/v1/devices", query: params)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Device)).from_json(response.body)
      if result.status == "success" && result.data
        self[:devices] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get devices: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get devices: #{response.status_code} - #{response.body}" }
      nil
    end
  end

  # Sensors API
  def get_sensors(limit : Int32 = 50, offset : Int32 = 0)
    params = "limit=#{limit}&offset=#{offset}"
    response = authenticated_request("get", "/api/v1/sensors", query: params)
    return unless response

    if response.success?
      result = Humly::ApiResponse(Array(Humly::Sensor)).from_json(response.body)
      if result.status == "success" && result.data
        self[:sensors] = result.data.not_nil!
        result.data.not_nil!
      else
        logger.error { "Failed to get sensors: #{result.message}" }
        nil
      end
    else
      logger.error { "Failed to get sensors: #{response.status_code} - #{response.body}" }
      nil
    end
  end
end
