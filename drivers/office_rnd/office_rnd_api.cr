require "uri"
require "uuid"

module OfficeRnD; end

class OfficeRnd::OfficeRndAPI < ACAEngine::Driver
  # Discovery Information
  generic_name :OfficeRnd
  descriptive_name "OfficeRnD REST API"

  default_settings({
    client_id:     "10000000",
    client_secret: "c5a6adc6-UUID-46e8-b72d-91395bce9565",
    scopes:        ["officernd.api.read", "officernd.api.write"],
  })

  @client_id : String = ""
  @client_secrets : String = ""
  @scopes : Array(String) = [] of String

  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @client_id = setting(String, :client_id)
    @app_key = setting(String, :app_key)
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    @auth_expiry < Time.utc
  end

  def get_token
    return @auth_token unless token_expired?
    auth_route = "https://identity.officernd.com/oauth/token"
    params = HTTP::Params.encode({
      "client_secret" => client_secret,
      "grant_type"    => "client_credentials",
      "scope"         => scopes.join(' '),
    })
    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }
    response = HTTP::Client.post(
      url: "#{auth_route}?#{params}",
      headers: headers,
    )
    body = response.body
    logger.debug { "received login response: #{body}" }

    if response.success?
      resp = TokenResponse.from_json(body.as(IO))
      token = resp.token
      @auth_expiry = Time.utc + (resp.expires_in - 5).seconds
      @auth_token = "Bearer #{resp.token}"
    else
      logger.error "authentication failed with HTTP #{response.status_code}"
      raise "failed to obtain access token"
    end
  end

  # Get a booking
  def booking(booking_id : String)
    get_request("/bookings/#{booking_id}", Booking)
  end

  # Get bookings in a date range for a particular room
  #
  def bookings(
    office_id : String? = nil,
    member_id : String? = nil,
    team_id : String? = nil
  )
    params = HTTP::Params.new
    params["office"] = office_id if office_id
    params["member"] = member_id if member_id
    params["team"] = team_id if team_id
    query_string = params.to_s
    url = query_string.empty? ? "/resources" : "/resources?#{query_string}"
    get_request(url, Array(Booking))
  end

  # Delete a booking
  #
  def delete_booking(booking_id : String)
    !!(delete_request("/bookings/#{booking_id}"))
  end

  # Make a booking
  #
  def create_bookings(bookings : Array(Booking))
    response = post("/bookingsbe/cp/oauth2/token", body: bookings.to_json, headers: {
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
      "Authorization" => get_token,
    })
  end

  # Create a booking
  #
  def create_booking(
    resource_id : String,
    booking_start : Time,
    booking_end : Time,
    summary : String? = nil,
    team_id : String? = nil,
    member_id : String? = nil,
    description : String? = nil,
    tentative : Boolean? = nil,
    free : Boolean? = nil
  )
    create_booking [Booking.new(
      resource_id: resource_id,
      booking_start: booking_start,
      booking_end: booking_end,
      summary: summary,
      team_id: team_id,
      member_id: member_id,
      description: description,
      tentative: tentative,
      free: free,
    )]
  end

  alias BookingArgument = NamedTuple(
    resource_id: String,
    booking_start: Time,
    booking_end: Time,
    summary: String?,
    team_id: String?,
    member_id: String?,
    description: String?,
    tentative: Boolean?,
    free: Boolean?,
  )

  def create_bookings(bookings : Array(BookingArgument))
    create_bookings(bookings.map { |booking| Booking.new(**booking) })
  end

  # List offices
  #
  def offices(name : String? = nil)
    url = name ? "/bookings" : "/bookings?name=#{name}"
    get_request(url, Array(Office))
  end

  # Get available rooms (resources) by
  # - type
  # - date range (available_from, available_to)
  # - office (office_id)
  # - resource name (name)
  def resources(
    type : Resource::Type? = nil,
    name : String? = nil,
    office_id : String? = nil,
    available_from : Time? = nil,
    available_to : Time? = nil
  )
    params = HTTP::Params.new
    params["type"] = type.to_s if type
    params["name"] = name if name
    params["office"] = office_id if office_id
    params["availableFrom"] = available_from.to_s if available_from
    params["availableTo"] = available_to.to_s if available_to
    query_string = params.to_s
    url = query_string.empty? ? "/resources" : "/resources?#{query_string}"
    get_request(url, Array(Resource))
  end

  # Data Models
  #############################################################################

  struct TokenResponse
    include JSON::Serializable
    property access_token : String
    property token_type : String
    property expires_in : Int32
    property scope : String
  end

  struct Office < Data
    @[JSON::Field(key: "_id")]
    getter id : String
    getter name : String
    getter country : String?
    getter state : String?
    getter city : String?
    getter address : String?
    getter timezone : String?
    getter image : String?
    @[JSON::Field(key: "isOpen")]
    getter is_open : Bool?
  end

  struct Booking < Data
    @[JSON::Field(key: "start")]
    getter booking_start : BookingTime
    @[JSON::Field(key: "end")]
    getter booking_end : BookingTime
    getter timezone : String # TODO: handle timezones
    getter source : String?
    getter summary : String?
    @[JSON::Field(key: "resourceId")]
    getter resource_id : String
    @[JSON::Field(key: "plan")]
    getter plan_id : String
    @[JSON::Field(key: "team")]
    getter team_id : String?
    @[JSON::Field(key: "member")]
    getter member_id : String?
    getter description : String?
    getter tentative : Boolean?
    getter free : Boolean?
    getter fees : Array(BookingFee)
    getter extras : JSON::Any

    def initialize(
      @resource_id : String,
      booking_start : Time,
      booking_end : Time,
      @summary : String? = nil,
      @team_id : String? = nil,
      @member_id : String? = nil,
      @description : String? = nil,
      @tentative : Boolean? = nil,
      @free : Boolean? = nil
    )
      unless @member_id || @team_id
        raise "Booking requires at least one of team_id or member_id"
      end
      @booking_start = BookingTime.new(booking_start)
      @booking_end = BookingTime.new(booking_end)
    end
  end

  struct BookingTime < Data
    @[JSON::Field(key: "dateTime")]
    getter time : Time

    def initialize(@time : Time); end
  end

  struct BookingFee < Data
    getter date : Time
    getter fee : Fee?
    @[JSON::Field(key: "extraFees")]
    getter extra_fees : Array(JSON::Any?)
    getter credits : Array(Credit)
  end

  struct Fee < Data
    getter name : String
    getter price : Int32
    getter quantity : Int32 = 1
    getter date : Time
    @[JSON::Field(key: "team")]
    getter team_id : String?
    @[JSON::Field(key: "office")]
    getter office_id : String
    @[JSON::Field(key: "member")]
    getter member_id : String?
    @[JSON::Field(key: "plan")]
    getter plan_id : String?
    getter refundable : Boolean?
    @[JSON::Field(key: "billInAdvance")]
    getter bill_in_advance : Boolean?
    @[JSON::Field(key: "isPersonal")]
    getter is_personal : Boolean?
  end

  struct Credit < Data
    getter count : Int32
    getter credit : String
  end

  struct Resource < Data
    getter name : String
    getter rate : Rate?
    getter office : Office
    getter room : Floor
    getter type : Type

    enum Type
      MeetingRoom
      PrivateOffices
      PrivateOfficeDesk
      DedicatedDesks
      HotDesks

      MAPPING = {
        MeetingRoom       => "meeting_room",
        PrivateOffices    => "team_room",
        PrivateOfficeDesk => "desk_tr",
        DedicatedDesks    => "desk",
        HotDesks          => "hotdesk",
      }

      def to_json(json : JSON::Builder)
        json.string(self.to_s)
      end

      def to_s
        MAPPING[self]
      end

      def parse(type : String)
        parsed = MAPPING.key_for?(type)
        raise ArgumentError.new("Unrecognised Resource::Type '#{type}'") unless parsed
        parsed
      end
    end
  end

  private abstract struct Data
    include JSON::Serializable
  end

  # Internal Helpers
  #############################################################################

  private macro get_request(path, result_type)
    begin
      %token = get_token
      %response = get({{path}}, headers: {
        "Accept" => "application/json",
        "Authorization" => %token
      })

      if %response.success?
        {{result_type}}.from_json(%response.body.as(IO))
      else
        expire_token! if %response.status_code == 401
        raise "unexpected response #{%response.status_code}\n#{%response.body}"
      end
    end
  end
end
