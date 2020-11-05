module Place; end

require "json"
require "oauth2"
require "placeos-driver/interface/locatable"

class Place::DeskBookingsLocations < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "PlaceOS Desk Bookings Locations"
  generic_name :DeskBookings
  description %(collects desk booking data from the staff API for visualising on a map)

  # The PlaceOS API
  uri_base "https://staff.app.api.com"

  default_settings({
    zone_filter: ["zone-12345"],

    # PlaceOS API creds, so we can query the zone metadata
    username:     "",
    password:     "",
    client_id:    "",
    redirect_uri: "",

    # time in seconds
    poll_rate:    60,
    booking_type: "desk",
  })

  @zone_filter : Array(String) = [] of String
  @poll_rate : Time::Span = 60.seconds
  @booking_type : String = "desk"

  @place_domain : URI = URI.parse("https://staff.app.api.com")
  @username : String = ""
  @password : String = ""
  @client_id : String = ""
  @redirect_uri : String = ""

  @running_a_spec : Bool = false

  def on_load
    on_update
  end

  def on_update
    @zone_filter = setting?(Array(String), :zone_filter) || [] of String
    @poll_rate = (setting?(Int32, :poll_rate) || 60).seconds

    # we use the Place Client to query the desk booking data
    @username = setting(String, :username)
    @password = setting(String, :password)
    @client_id = setting(String, :client_id)
    @redirect_uri = setting(String, :redirect_uri)

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @place_domain = URI.parse(config.uri.not_nil!)

    @running_a_spec = setting?(Bool, :running_a_spec) || false

    map_zones
    schedule.clear
    schedule.every(@poll_rate) { query_desk_bookings }
    schedule.in(5.seconds) { query_desk_bookings }
  end

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }
    bookings = @bookings[email]? || [] of Booking
    map_bookings(bookings)
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil)
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }
    found = [] of String
    @known_users.each { |user_id, (user_email, _name)|
      found << user_id if email == user_email
    }
    found
  end

  def check_ownership_of(mac_address : String)
    logger.debug { "searching for owner of #{mac_address}" }
    if user_details = @known_users[mac_address]?
      email, name = user_details
      {
        location:    :desk_booking,
        assigned_to: email,
        mac_address: mac_address,
        name:        name,
      }
    end
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    bookings = [] of Booking
    @bookings.each_value(&.each { |booking|
      next unless zone_id.in?(booking.zones)
      bookings << booking
    })
    map_bookings(bookings)
  end

  protected def map_bookings(bookings)
    bookings.map do |booking|
      level = nil
      building = nil
      booking.zones.each do |zone_id|
        tags = @zone_mappings[zone_id]
        level = zone_id if tags.includes? "level"
        building = zone_id if tags.includes? "building"
        break if level && building
      end

      {
        location:    :desk_booking,
        at_location: booking.checked_in,
        map_id:      booking.asset_id,
        level:       level,
        building:    building,
        mac:         booking.user_id,

        booking_start: booking.booking_start,
        booking_end:   booking.booking_end,
      }
    end
  end

  # ===================================
  # DESK AND ZONE QUERIES
  # ===================================
  # zone id => tags
  @zone_mappings = {} of String => Array(String)

  class ZoneDetails
    include JSON::Serializable
    property tags : Array(String)
  end

  protected def map_zones
    @zone_mappings = Hash(String, Array(String)).new do |hash, zone_id|
      response = get("/api/engine/v2/zones/#{zone_id}", headers: {
        "Accept"        => "application/json",
        "Authorization" => token,
      })
      raise "issue loading zone #{zone_id}: #{response.status_code}" unless response.success?
      zone = ZoneDetails.from_json(response.body)
      hash[zone_id] = zone.tags
    end
  end

  class Booking
    include JSON::Serializable

    property id : Int64

    property user_id : String
    property user_email : String
    property user_name : String
    property asset_id : String
    property zones : Array(String)
    property booking_type : String

    property booking_start : Int64
    property booking_end : Int64

    property timezone : String?
    property title : String?
    property description : String?

    property checked_in : Bool
    property rejected : Bool
    property approved : Bool
  end

  # Email => Array of bookings
  @bookings : Hash(String, Array(Booking)) = Hash(String, Array(Booking)).new

  # UserID =>  {Email, Name}
  @known_users : Hash(String, Tuple(String, String)) = Hash(String, Tuple(String, String)).new

  def query_desk_bookings
    params = {
      "period_start" => Time.utc.to_unix.to_s,
      "period_end"   => 30.minutes.from_now.to_unix.to_s,
      "type"         => @booking_type,
    }
    params["zones"] = @zone_filter.join(",") unless @zone_filter.empty?

    # Get the existing bookings from the API to check if there is space
    response = get("/api/staff/v1/bookings", params, {
      "Accept"        => "application/json",
      "Authorization" => token,
    })
    raise "issue loading list of bookings #{@zone_filter}: #{response.status_code}" unless response.success?

    bookings = Array(Booking).from_json(response.body)

    new_bookings = Hash(String, Array(Booking)).new do |hash, key|
      hash[key] = [] of Booking
    end

    bookings.each do |booking|
      next if booking.rejected
      new_bookings[booking.user_email] << booking
      @known_users[booking.user_id] = {booking.user_email, booking.user_name}
    end

    @bookings = new_bookings
  end

  # ===================================
  # PLACEOS AUTHENTICATION:
  # ===================================
  @access_token : String = ""
  @access_expires : Time = Time.unix(0)

  protected def authenticate : String
    uri = @place_domain
    host = uri.port ? "#{uri.host}:#{uri.port}" : uri.host.not_nil!
    origin = "#{uri.scheme}://#{host}"

    # Create oauth client, optionally pass custom URIs if needed,
    # if the authorize or token URIs are not the standard ones
    # (they can also be absolute URLs)
    oauth2_client = OAuth2::Client.new(host, @client_id, "",
      redirect_uri: @redirect_uri,
      authorize_uri: "#{origin}/auth/oauth/authorize",
      token_uri: "#{origin}/auth/oauth/token")

    access_token = oauth2_client.get_access_token_using_resource_owner_credentials(
      @username,
      @password,
      "public"
    ).as(OAuth2::AccessToken::Bearer)

    @access_expires = (access_token.expires_in.not_nil! - 300).seconds.from_now
    @access_token = "Bearer #{access_token.access_token}"
  end

  protected def token : String
    # Don't perform OAuth if we are testing the driver
    return "spec-test" if @running_a_spec
    return @access_token if valid_token?
    authenticate
  end

  protected def valid_token?
    Time.utc < @access_expires
  end
end

# Deal with bad SSL certificate
class OpenSSL::SSL::Context::Client
  def initialize(method : LibSSL::SSLMethod = Context.default_method)
    super(method)

    self.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
      self.default_verify_param = "ssl_server"
    {% end %}
  end
end
