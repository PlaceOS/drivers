require "uri"
require "jwt"
require "./models"
require "placeos-driver"

# Documentation:
# https://apiguide.smartalock.com/
# https://documenter.getpostman.com/view/8843075/SVmwvctF?version=latest#3bfbb050-722d-4433-889a-8793fa90af9c

class Floorsense::Desks < PlaceOS::Driver
  # Discovery Information
  generic_name :Floorsense
  descriptive_name "Floorsense Desk Tracking (WS)"

  uri_base "wss://_your_subdomain_.floorsense.com.au/ws"

  default_settings({
    username:    "srvc_acct",
    password:    "password!",
    ws_username: "srvc_acct",
    ws_password: "password!",
  })

  @username : String = ""
  @password : String = ""
  @ws_username : String = ""
  @ws_password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago
  @user_cache : Hash(String, User) = {} of String => User

  @controllers : Hash(Int32, ControllerInfo) = {} of Int32 => ControllerInfo

  # Locker key => controller id
  @lockers : Hash(String, LockerInfo) = {} of String => LockerInfo

  def on_load
    transport.tokenizer = Tokenizer.new("\r\n")
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @ws_username = setting?(String, :ws_username)
    @ws_password = setting?(String, :ws_password)

    schedule.clear
    schedule.every(1.hour) { sync_locker_list }
    schedule.in(5.seconds) { sync_locker_list }
  end

  def connected
    # authenticate
    # ws_post("/auth", {username: @ws_username, password: @ws_password}, priority: 99, name: "auth")
    ws_post("/auth", {user: "kiosk"}, priority: 99, name: "auth")
  end

  protected def ws_post(uri, body = nil, **options)
    request = "POST #{uri}\r\n#{body ? body.to_json : "{}"}\r\n"
    logger.debug { "requesting: #{request}" }
    send(request, **options)
  end

  protected def ws_get(uri, **options)
    request = "GET #{uri}\r\n"
    logger.debug { "requesting: #{request}" }
    send(request, **options)
  end

  def received(data, task)
    string = String.new(data).rstrip
    logger.debug { "websocket sent: #{string}" }
    payload = Payload.from_json(string)

    case payload
    in Response
      if !payload.result
        logger.warn { "task #{task.try &.name} failed.." }
        disconnect
        return task.try &.abort
      end

      case task.try &.name
      when "auth"
        logger.debug { "authentication success!" }

        # subscribe to all events
        ws_post("/sub", {mask: 255}, name: "sub")
      when "sub"
        logger.debug { "subscribed to events" }
      else
        logger.warn { "unknown task: #{(task.try &.name).inspect}" }
      end
      task.try &.success
    in Event
      self["event_#{payload.code}"] = payload.info || payload.message
    in Payload
      logger.error { "base class, this case will never occur" }
    end
  rescue error
    logger.error(exception: error) { "failed to parse: #{string.inspect}" }
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

    response = post("/restapi/login",
      body: "username=#{URI.encode_www_form @username}&password=#{URI.encode_www_form @password}",
      headers: {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Accept"       => "application/json",
      }
    )

    data = response.body.not_nil!
    logger.debug { "received login response #{data}" }

    if response.success?
      resp = Resp(AuthInfo).from_json(data)
      token = resp.info.not_nil!.token
      payload, _ = JWT.decode(token, verify: false, validate: false)
      @auth_expiry = (Time.unix payload["exp"].as_i64) - 5.minutes
      @auth_token = "Bearer #{token}"
    else
      case response.status_code
      when 401
        resp = Resp(AuthInfo).from_json(data)
        logger.warn { "#{resp.message} (#{resp.code})" }
      else
        logger.error { "authentication failed with HTTP #{response.status_code}" }
      end
      raise "failed to obtain access token"
    end
  end

  protected def check_success(response) : Bool
    return true if response.success?
    expire_token! if response.status_code == 401
    raise "unexpected response #{response.status_code}\n#{response.body}"
  end

  macro parse(response, klass, &modify)
    check_success({{response}})
    check_response Resp({{klass}}).from_json({{response}}.body.not_nil!) {{modify}}
  end

  def default_headers
    {
      "Accept"        => "application/json",
      "Authorization" => get_token,
    }
  end

  def sync_locker_list
    lockers = {} of String => LockerInfo
    controller_list.each do |controller_id, controller|
      next unless controller.lockers
      lockers(controller_id).each do |locker|
        next unless locker.key
        locker.controller_id = controller_id
        lockers[locker.key.not_nil!] = locker
      end
    end
    @lockers = lockers
  end

  def controller_list
    response = get("/restapi/slave-list", headers: default_headers)
    controllers = parse response, Array(ControllerInfo)

    mappings = {} of Int32 => ControllerInfo
    controllers.each { |ctrl| mappings[ctrl.controller_id] = ctrl }
    self[:controllers] = mappings
    @controllers = mappings
  end

  def all_lockers
    return @lockers.values unless @lockers.empty?
    sync_locker_list.values
  end

  def lockers(controller_id : String | Int32)
    response = get("/restapi/locker-list?cid=#{controller_id}", headers: default_headers)
    parse response, Array(LockerInfo)
  end

  def locker(locker_key : String)
    lock = @lockers[locker_key]
    response = get("/restapi/locker-status?cid=#{lock.controller_id}&bid=#{lock.bus_id}&lid=#{lock.locker_id}", headers: default_headers)
    parse response, LockerInfo
  end

  enum LedState
    Off
    On
    Slow
    Medium
    Fast
  end

  def locker_control(
    locker_key : String,
    light : Bool? = nil,
    led : LedState? = nil,
    led_colour : String? = nil,
    buzzer : String? = nil,
    usb_charging : String? = nil,
    detect : Bool? = nil
  )
    lock = @lockers[locker_key]

    response = post("/restapi/locker-control", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("cid", lock.controller_id.to_s)
      form.add("bid", lock.bus_id.to_s)
      form.add("lid", lock.locker_id.to_s)

      form.add("light", light ? "on" : "off") if !light.nil?
      form.add("led", led.to_s.downcase) if led
      form.add("led-colour", led_colour) if led_colour
      form.add("buzzer", buzzer) if buzzer
      form.add("usbchg", usb_charging) if usb_charging
      form.add("detect", "true") if detect
    })

    check_success(response)
  end

  def locker_reservation(
    locker_key : String,
    user_id : String,
    type : String? = nil,
    duration : Int32? = nil,
    restype : String = "adhoc" # also supports fixed
  )
    lock = @lockers[locker_key]

    response = post("/restapi/res-create", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("cid", lock.controller_id.to_s)
      form.add("key", locker_key)
      form.add("uid", user_id)

      form.add("type", type) if type
      form.add("duration", duration.to_s) if duration
      form.add("restype", restype)
    })

    parse response, LockerBooking
  end

  def locker_reservations(active : Bool? = nil, user_id : String? = nil)
    query = URI::Params.build { |form|
      form.add("uid", user_id) if user_id
      form.add("active", "1") if active
    }

    response = get("/restapi/res-list?#{query}", headers: default_headers)
    parse response, Array(LockerBooking)
  end

  @[Security(Level::Support)]
  def locker_release(reservation_id : String)
    response = post("/restapi/res-release", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("resid", reservation_id)
    })

    check_success(response)
  end

  @[Security(Level::Support)]
  def locker_change_pin(reservation_id : String, pin : Int32)
    response = post("/restapi/res", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("resid", reservation_id)
      form.add("pin", pin.to_s)
    })

    check_success(response)
  end

  @[Security(Level::Support)]
  def locker_unlock(
    locker_key : String,
    user_id : String
  )
    lock = @lockers[locker_key]

    response = post("/restapi/locker-unlock", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("cid", lock.controller_id.to_s)
      form.add("key", locker_key)
      form.add("uid", user_id)
    })

    check_success(response)
  end

  def floors
    response = get("/restapi/floorplan-list", headers: default_headers)
    parse response, Array(Floor)
  end

  def desks(plan_id : String | Int32)
    response = get("/restapi/floorplan-desk?planid=#{plan_id}", headers: default_headers)
    parse response, Array(DeskStatus)
  end

  def bookings(plan_id : String, period_start : Int64? = nil, period_end : Int64? = nil)
    period_start ||= Time.utc.to_unix
    period_end ||= 15.minutes.from_now.to_unix
    uri = "/restapi/floorplan-booking?planid=#{plan_id}&start=#{period_start}&finish=#{period_end}"

    response = get(uri, headers: default_headers)
    bookings_map = parse response, Hash(String, Array(BookingStatus))
    bookings_map.each do |_id, bookings|
      # get the user information
      bookings.each { |booking| booking.user = get_user(booking.uid) }
    end
    bookings_map
  end

  def get_booking(booking_id : String | Int64)
    response = get("/restapi/booking?bkid=#{booking_id}", headers: default_headers)
    booking = parse response, BookingStatus
    booking.user = get_user(booking.uid)
    booking
  end

  def confirm_booking(booking_id : String | Int64)
    response = post("/restapi/booking-confirm", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("bkid", booking_id.to_s)
      form.add("method", "1")
    })
    parse response, JSON::Any
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
    desks_on_plan = desks(plan_id)
    desk = desks_on_plan.find(&.key.==(key))

    raise "could not find desk #{key} on plan #{plan_id}" unless desk

    now = time_zone ? Time.local(Time::Location.load(time_zone)) : Time.local
    starting ||= now.at_beginning_of_day.to_unix
    ending ||= now.at_end_of_day.to_unix

    response = post("/restapi/booking-create", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("uid", user_id.to_s)
      form.add("cid", desk.cid.to_s)
      form.add("key", key)
      form.add("bktype", booking_type)
      form.add("desc", description.not_nil!) if description
      form.add("start", starting.to_s)
      form.add("finish", ending.to_s)
      form.add("confexpiry", ending.to_s)
    })

    booking = parse response, BookingStatus
    booking.user = get_user(booking.uid)
    booking
  end

  def release_booking(booking_id : String | Int64)
    response = post("/restapi/booking-release", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build(&.add("bkid", booking_id.to_s)))

    check_success(response)
  end

  def create_user(
    name : String,
    email : String,
    description : String? = nil,
    extid : String? = nil,
    pin : String? = nil,
    usertype : String = "user"
  )
    response = post("/restapi/user-create", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("name", name)
      form.add("email", email)
      form.add("desc", description.not_nil!) if description
      form.add("pin", pin.not_nil!) if pin
      form.add("extid", extid.not_nil!) if extid
      form.add("usertype", "user")
    })

    user = parse response, User
    @user_cache[user.uid] = user
    user
  end

  def create_rfid(
    user_id : String,
    card_number : String,
    description : String? = nil
  )
    response = post("/restapi/rfid-create", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("uid", user_id)
      form.add("csn", card_number)
      form.add("desc", description.not_nil!) if description
    })

    parse(response, User) { |resp| resp || JSON::Any.new(true) }
  end

  def delete_rfid(card_number : String)
    response = post("/restapi/rfid-delete", headers: {
      "Accept"        => "application/json",
      "Authorization" => get_token,
      "Content-Type"  => "application/x-www-form-urlencoded",
    }, body: URI::Params.build { |form|
      form.add("csn", card_number)
    })

    check_success(response)
  end

  def get_rfid(card_number : String)
    response = get("/restapi/rfid?csn=#{card_number}", headers: default_headers)
    parse response, RFID
  end

  def get_user(user_id : String)
    existing = @user_cache[user_id]?
    return existing if existing

    response = get("/restapi/user?uid=#{user_id}", headers: default_headers)
    user = parse response, User
    @user_cache[user_id] = user
    user
  end

  def user_list(email : String? = nil, name : String? = nil, description : String? = nil)
    query = URI::Params.build { |form|
      form.add("email", email.not_nil!) if email
      form.add("name", name.not_nil!) if name
      form.add("desc", description.not_nil!) if description
    }

    response = get("/restapi/user-list?#{query}", headers: default_headers)
    parse response, Array(User)
  end

  def event_log(codes : Array(String | Int32), event_id : Int64? = nil, after : Int64? = nil, limit : Int32 = 1)
    query = URI::Params.build { |form|
      form.add("codes", codes.join(",", &.to_s))
      form.add("after", after.not_nil!.to_s) if after
      form.add("event_id", event_id.not_nil!.to_s) if event_id
      form.add("limit", limit.to_s)
    }

    response = get("/restapi/event-log?#{query}", headers: default_headers)
    logs = parse response, Array(LogEntry)
    logs.sort do |a, b|
      if a.eventtime == b.eventtime
        a.eventid <=> b.eventid
      else
        a.eventtime <=> b.eventtime
      end
    end
  end

  def at_location(controller_id : String, desk_key : String)
    response = get("/restapi/user-locate?cid=#{controller_id}&desk_key=#{desk_key}", headers: default_headers)
    logger.debug { "at_location response: #{response.body}" }
    users = parse response, Array(User)
    users.first?
  end

  @[Security(Level::Support)]
  def clear_user_cache!
    @user_cache.clear
  end

  def locate(key : String, controller_id : String? = nil)
    uri = if controller_id
            "/restapi/user-locate?cid=#{controller_id}&key=#{URI.encode_www_form key}"
          else
            "/restapi/user-locate?name=#{URI.encode_www_form key}"
          end

    response = get(uri, headers: default_headers)
    parse response, Array(UserLocation)
  end

  protected def check_response(resp)
    check_response(resp) { |value| value.not_nil! }
  end

  protected def check_response(resp)
    if resp.result
      yield resp.info
    else
      raise "bad response result (#{resp.code}) #{resp.message}"
    end
  end
end
