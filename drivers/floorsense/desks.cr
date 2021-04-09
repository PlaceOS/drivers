require "uri"
require "jwt"
require "./models"

module Floorsense; end

# Documentation:
# https://apiguide.smartalock.com/
# https://documenter.getpostman.com/view/8843075/SVmwvctF?version=latest#3bfbb050-722d-4433-889a-8793fa90af9c

class Floorsense::Desks < PlaceOS::Driver
  # Discovery Information
  generic_name :Floorsense
  descriptive_name "Floorsense Desk Tracking"

  uri_base "https://_your_subdomain_.floorsense.com.au"

  default_settings({
    username: "srvc_acct",
    password: "password!",
  })

  @username : String = ""
  @password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago
  @user_cache : Hash(String, User) = {} of String => User

  def on_load
    on_update
  end

  def on_update
    @username = URI.encode_www_form setting(String, :username)
    @password = URI.encode_www_form setting(String, :password)
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    now = Time.utc
    @auth_expiry < now
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/restapi/login", body: "username=#{@username}&password=#{@password}", headers: {
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    })

    data = response.body.not_nil!
    logger.debug { "received login response #{data}" }

    if response.success?
      resp = AuthResponse.from_json(data)
      token = resp.info.not_nil!.token
      payload, _ = JWT.decode(token, verify: false, validate: false)
      @auth_expiry = (Time.unix payload["exp"].as_i64) - 5.minutes
      @auth_token = "Bearer #{token}"
    else
      case response.status_code
      when 401
        resp = AuthResponse.from_json(data)
        logger.warn { "#{resp.message} (#{resp.code})" }
      else
        logger.error { "authentication failed with HTTP #{response.status_code}" }
      end
      raise "failed to obtain access token"
    end
  end

  def floors
    token = get_token
    uri = "/restapi/floorplan-list"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      check_response FloorsResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def desks(plan_id : String)
    token = get_token
    uri = "/restapi/floorplan-desk?planid=#{plan_id}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      check_response DesksResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def bookings(plan_id : String, period_start : Int64? = nil, period_end : Int64? = nil)
    token = get_token
    period_start ||= Time.utc.to_unix
    period_end ||= 15.minutes.from_now.to_unix
    uri = "/restapi/floorplan-booking?planid=#{plan_id}&start=#{period_start}&finish=#{period_end}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      bookings_map = check_response(BookingsResponse.from_json(response.body.not_nil!))
      bookings_map.each do |_id, bookings|
        # get the user information
        bookings.each { |booking| booking.user = get_user(booking.uid) }
      end
      bookings_map
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def get_booking(booking_id : String | Int64)
    token = get_token
    uri = "/restapi/booking?bkid=#{booking_id}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      booking = check_response BookingResponse.from_json(response.body.not_nil!)
      booking.user = get_user(booking.uid)
      booking
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def create_booking(
    user_id : String | Int64,
    plan_id : String | Int32,
    key : String,
    description : String? = nil,
    starting : Int64? = nil,
    ending : Int64? = nil,
    time_zone : String? = nil,
    booking_type : String = "advance"
  )
    token = get_token
    uri = "/restapi/booking-create"

    now = time_zone ? Time.local(Time::Location.load(time_zone)) : Time.local
    starting ||= now.at_beginning_of_day.to_unix
    ending ||= now.at_end_of_day.to_unix

    response = post(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("uid", user_id.to_s)
      form.add("planid", plan_id.to_s)
      form.add("key", key)
      form.add("bktype", booking_type)
      form.add("desc", description.not_nil!) if description
      form.add("start", starting.to_s)
      form.add("finish", ending.to_s)
    })

    if response.success?
      booking = check_response BookingResponse.from_json(response.body.not_nil!)
      booking.user = get_user(booking.uid)
      booking
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def release_booking(booking_id : String | Int64)
    token = get_token
    uri = "/restapi/booking-release"

    response = post(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build(&.add("bkid", booking_id.to_s)))

    if response.success?
      true
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def create_user(
    name : String,
    email : String,
    description : String? = nil,
    extid : String? = nil,
    pin : String? = nil,
    usertype : String = "user"
  )
    token = get_token
    uri = "/restapi/user-create"

    response = post(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("name", name)
      form.add("email", email)
      form.add("desc", description.not_nil!) if description
      form.add("pin", pin.not_nil!) if pin
      form.add("extid", extid.not_nil!) if extid
      form.add("usertype", "user")
    })

    if response.success?
      user = check_response UserResponse.from_json(response.body.not_nil!)
      @user_cache[user.uid] = user
      user
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def create_rfid(
    user_id : String,
    card_number : String,
    description : String? = nil
  )
    token = get_token
    uri = "/restapi/rfid-create"

    response = post(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("uid", user_id)
      form.add("csn", card_number)
      form.add("desc", description.not_nil!) if description
    })

    if response.success?
      check_response RFIDResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def delete_rfid(card_number : String)
    token = get_token
    uri = "/restapi/rfid-delete"

    response = post(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("csn", card_number)
    })

    if response.success?
      true
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def get_user(user_id : String)
    existing = @user_cache[user_id]?
    return existing if existing

    token = get_token
    uri = "/restapi/user?uid=#{user_id}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      user = check_response UserResponse.from_json(response.body.not_nil!)
      @user_cache[user_id] = user
      user
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def user_list(email : String? = nil, name : String? = nil, description : String? = nil)
    query = URI::Params.build { |form|
      form.add("email", email.not_nil!) if email
      form.add("name", name.not_nil!) if name
      form.add("desc", description.not_nil!) if description
    }

    token = get_token
    uri = "/restapi/user-list?#{query}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      check_response UsersResponse.from_json(response.body.not_nil!)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def event_log(codes : Array(String | Int32), event_id : Int64? = nil, limit : Int32 = 1)
    token = get_token

    uri = if event_id
            "/restapi/event-log?codes=#{codes.join(",", &.to_s)}&limit=#{limit}&event_id=#{event_id}"
          else
            "/restapi/event-log?codes=#{codes.join(",", &.to_s)}&limit=#{limit}"
          end

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      # Responses are not returned sorted, we want the oldest event first
      # oldest first as we want to process events in the order that they happen
      check_response(LogResponse.from_json(response.body.not_nil!)).sort { |a, b| a.eventtime <=> b.eventtime }
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  def at_location(controller_id : String, desk_key : String)
    token = get_token
    uri = "/restapi/user-locate?cid=#{controller_id}&desk_key=#{desk_key}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    logger.debug { "at_location response: #{response.body}" }

    if response.success?
      users = check_response UsersResponse.from_json(response.body.not_nil!)
      users.first?
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  @[Security(Level::Support)]
  def clear_user_cache!
    @user_cache.clear
  end

  def locate(key : String, controller_id : String? = nil)
    token = get_token
    uri = if controller_id
            "/restapi/user-locate?cid=#{controller_id}&key=#{URI.encode_www_form key}"
          else
            "/restapi/user-locate?name=#{URI.encode_www_form key}"
          end

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      resp = LocateResponse.from_json(response.body.not_nil!)
      # Select users where there is a desk key found
      check_response(resp).select(&.key)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  protected def check_response(resp)
    if resp.result
      resp.info.not_nil!
    else
      raise "bad response result (#{resp.code}) #{resp.message}"
    end
  end
end
