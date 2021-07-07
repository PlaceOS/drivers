require "uri"
require "uuid"
require "placeos-driver"
require "./models"

module OfficeRnd
  class OfficeRndAPI < PlaceOS::Driver
    # Discovery Information
    generic_name :OfficeRnd
    descriptive_name "OfficeRnD REST API"

    default_settings({
      client_id:     "10000000",
      client_secret: "c5a6adc6-UUID-46e8-b72d-91395bce9565",
      scopes:        ["officernd.api.read", "officernd.api.write"],
      test_auth:     true,
    })

    @client_id : String = ""
    @client_secret : String = ""
    @scopes : Array(String) = [] of String

    @test_auth : Bool = false
    @auth_token : String = ""
    @auth_expiry : Time = 1.minute.ago

    def on_load
      on_update
      @test_auth = setting(Bool, :test_auth)
    end

    def on_update
      @client_id = setting(String, :client_id)
      @client_secret = setting(String, :client_secret)
      @scopes = setting(Array(String), :scopes)
    end

    def expire_token!
      @auth_expiry = 1.minute.ago
    end

    def token_expired?
      @auth_expiry < Time.utc
    end

    def get_token
      return @auth_token unless token_expired?
      auth_route = @test_auth ? "http://localhost:17839/oauth/token" : "https://identity.officernd.com/oauth/token"
      params = HTTP::Params.encode({
        "client_id"     => @client_id,
        "client_secret" => @client_secret,
        "grant_type"    => "client_credentials",
        "scope"         => @scopes.join(' '),
      })
      headers = HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "Accept"       => "application/json",
      }
      response = HTTP::Client.post(
        url: auth_route,
        headers: headers,
        body: params,
      )
      body = response.body
      logger.debug { "received login response: #{body}" }

      if response.success?
        resp = TokenResponse.from_json(body)
        @auth_expiry = Time.utc + (resp.expires_in - 5).seconds
        @auth_token = "Bearer #{resp.access_token}"
      else
        logger.error { "authentication failed with HTTP #{response.status_code}" }
        raise "failed to obtain access token"
      end
    end

    # Floor
    ###########################################################################

    # Get a floor
    #
    def floor(floor_id : String)
      get_request("/floors/#{floor_id}", Floor)
    end

    # Get floors
    #
    def floors(office_id : String?, name : String?)
      params = HTTP::Params.new
      params["office"] = office_id if office_id
      params["name"] = name if name
      query_string = params.to_s
      path = query_string.empty? ? "/floors" : "/floors?#{query_string}"
      get_request(path, Array(Floor))
    end

    # Booking
    ###########################################################################

    # Get bookings for a resource for a given time span
    #
    def resource_bookings(
      resource_id : String,
      range_start : Time = Time.utc - 5.minutes,
      range_end : Time = Time.utc + 24.hours,
      office_id : String? = nil,
      member_id : String? = nil,
      team_id : String? = nil
    ) : Array(Booking)
      time_span = (range_start..range_end)
      bookings(
        office_id: office_id,
        member_id: member_id,
        team_id: team_id,
      ).select! do |booking|
        booking.resource_id == resource_id && booking.overlaps?(time_span)
      end
    end

    # Get a booking
    #
    def booking(booking_id : String)
      get_request("/bookings/#{booking_id}", Booking)
    end

    # Get bookings
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
      path = query_string.empty? ? "/bookings" : "/bookings?#{query_string}"
      get_request(path, Array(Booking))
    end

    # Delete a booking
    #
    def delete_booking(booking_id : String)
      !!(delete_request("/bookings/#{booking_id}"))
    end

    # Make a booking
    #
    def create_bookings(bookings : Array(Booking))
      response = post("/bookings", body: bookings.to_json, headers: {
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "Authorization" => get_token,
      })
      unless response.success?
        expire_token! if response.status_code == 401
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end
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
      tentative : Bool? = nil,
      free : Bool? = nil
    )
      create_bookings [Booking.new(
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
      tentative: Bool?,
      free: Bool?,
    )

    def create_bookings(bookings : Array(BookingArgument))
      create_bookings(bookings.map { |booking| Booking.new(**booking) })
    end

    # Office
    ###########################################################################

    # List offices
    #
    def offices
      path = "/offices"
      get_request(path, Array(Office))
    end

    # Retrieve office
    #
    def office(name : String)
      path = "/offices/#{name}"
      get_request(path, Office)
    end

    # Resource
    ###########################################################################

    # Get available rooms (resources) by
    # - type
    # - date range (available_from, available_to)
    # - office (office_id)
    # - resource name (name)
    def resources(
      type : (Resource::Type | String)? = nil,
      name : String? = nil,
      office_id : String? = nil,
      available_from : Time? = nil,
      available_to : Time? = nil
    )
      type = Resource::Type.parse(type) if type.is_a?(String)
      params = HTTP::Params.new
      params["type"] = type.to_s if type
      params["name"] = name if name
      params["office"] = office_id if office_id
      params["availableFrom"] = available_from.to_s if available_from
      params["availableTo"] = available_to.to_s if available_to
      query_string = params.to_s
      path = query_string.empty? ? "/resources" : "/resources?#{query_string}"
      get_request(path, Array(Resource))
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
          {{result_type}}.from_json(%response.body)
        else
          expire_token! if %response.status_code == 401
          raise "unexpected response #{%response.status_code}\n#{%response.body}"
        end
      end
    end
  end
end
