require "uri"
require "jwt"

module Floorsense; end

# Documentation: https://documenter.getpostman.com/view/8843075/SVmwvctF?version=latest#3bfbb050-722d-4433-889a-8793fa90af9c

class Floorsense::Desks < PlaceOS::Driver
  # Discovery Information
  generic_name :Desks
  descriptive_name "Floorsense Desk Tracking"

  default_settings({
    username: "srvc_acct",
    password: "password!",
  })

  @username : String = ""
  @password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @username = URI.encode_www_form setting(String, :username)
    @password = URI.encode_www_form setting(String, :password)
  end

  class AuthResponse
    include JSON::Serializable

    class Info
      include JSON::Serializable

      property token : String
      property sessionid : String
    end

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool
    property message : String?

    # Returned on failure
    property code : Int32?

    # Returned on success
    property info : Info?
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
        logger.warn "#{resp.message} (#{resp.code})"
      else
        logger.error "authentication failed with HTTP #{response.status_code}"
      end
      raise "failed to obtain access token"
    end
  end

  class DeskStatus
    include JSON::Serializable

    property cid : Int32
    property cached : Bool
    property reservable : Bool
    property netid : Int32
    property status : Int32
    property deskid : Int32

    property hwfeat : Int32
    property hardware : String

    @[JSON::Field(converter: Time::EpochConverter)]
    property created : Time
    property key : String
    property occupied : Bool
    property uid : String
    property eui64 : String

    @[JSON::Field(key: "type")]
    property desk_type : String
    property firmware : String
    property features : Int32
    property freq : String
    property groupid : Int32
    property bkid : String
    property planid : Int32
    property reserved : Bool
    property confirmed : Bool
    property privacy : Bool
    property occupiedtime : Int32
  end

  class DesksResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(DeskStatus)?
  end

  def desks(group_id : String)
    token = get_token
    uri = "/restapi/floorplan-desk?planid=#{group_id}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      resp = DesksResponse.from_json(response.body.not_nil!)
      resp.info.not_nil!
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  class UserLocation
    include JSON::Serializable

    property name : String
    property uid : String

    # Optional properties (when a user is located):

    @[JSON::Field(converter: Time::EpochConverter)]
    property start : Time?

    @[JSON::Field(converter: Time::EpochConverter)]
    property finish : Time?

    property planid : Int32?
    property occupied : Bool?
    property groupid : Int32?
    property key : String?
    property floorname : String?
    property cid : Int32?
    property occupiedtime : Int32?
    property groupname : String?
    property privacy : Bool?
    property confirmed : Bool?
    property active : Bool?
  end

  class LocateResponse
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property msg_type : String
    property result : Bool

    # Returned on failure
    property message : String?
    property code : Int32?

    # Returned on success
    property info : Array(UserLocation)?
  end

  def locate(user : String)
    token = get_token
    uri = "/restapi/user-locate?name=#{URI.encode_www_form user}"

    response = get(uri, headers: {
      "Accept"        => "application/json",
      "Authorization" => token,
    })

    if response.success?
      resp = LocateResponse.from_json(response.body.not_nil!)
      # Select users where there is a desk key found
      resp.info.not_nil!.select(&.key)
    else
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end
end
