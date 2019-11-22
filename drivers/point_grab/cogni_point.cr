require "uri"
require "uuid"

module PointGrab; end

# Documentation: https://aca.im/driver_docs/PointGrab/CogniPointAPI2-1.pdf

class PointGrab::CogniPoint < ACAEngine::Driver
  # Discovery Information
  generic_name :CogniPoint
  descriptive_name "PointGrab CogniPoint REST API"

  default_settings({
    user_id: "10000000",
    app_key: "c5a6adc6-UUID-46e8-b72d-91395bce9565"
  })

  @user_id : String = ""
  @app_key : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @user_id = setting(String, :user_id)
    @app_key = setting(String, :app_key)
  end

  class TokenResponse
    include JSON::Serializable

    property token : String
    property expires_in : Int32
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    @auth_expiry < Time.utc
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/be/cp/oauth2/token", body: "grant_type=client_credentials", headers: {
      "Content-Type"  => "application/x-www-form-urlencoded",
      "Accept"        => "application/json",
      "Authorization" => "Basic #{Base64.strict_encode("#{@user_id}:#{@app_key}")}"
    })

    body = response.body
    logger.debug { "received login response: #{body}" }

    if response.success?
      resp = TokenResponse.from_json(body.not_nil!)
      token = resp.token
      @auth_expiry = Time.utc + (resp.expires_in - 5).seconds
      @auth_token = "Bearer #{resp.token}"
    else
      logger.error "authentication failed with HTTP #{response.status_code}"
      raise "failed to obtain access token"
    end
  end

  macro get_request(path, result_type)
    begin
      %token = get_token
      %response = get({{path}}, headers: {
        "Accept" => "application/json",
        "Authorization" => %token
      })

      if %response.success?
        {{result_type}}.from_json(%response.body.not_nil!)
      else
        expire_token! if %response.status_code == 401
        raise "unexpected response #{%response.status_code}\n#{%response.body}"
      end
    end
  end

  class Customer
    include JSON::Serializable

    property id : String
    property name : String
  end

  def customers
    customers = get_request("/be/cp/v2/customers", NamedTuple(endCustomers: Array(Customer)))
    customers[:endCustomers]
  end

  class GeoPosition
    include JSON::Serializable

    property latitude : Float64
    property longitude : Float64
  end

  class MetricPositions
    include JSON::Serializable

    @[JSON::Field(key: "posX")]
    property pos_x : Float64

    @[JSON::Field(key: "posY")]
    property pos_y : Float64
  end

  class Site
    include JSON::Serializable

    property id : String
    property name : String

    class Location
      include JSON::Serializable

      @[JSON::Field(key: "houseNo")]
      property house_number : String
      property street : String
      property city : String
      property county : String
      property state : String
      property country : String
      property zip : String

      @[JSON::Field(key: "geoPosition")]
      property geo_position : GeoPosition
    end

    @[JSON::Field(key: "customerId")]
    property customer_id : String
  end

  def sites
    sites = get_request("/be/cp/v2/sites", NamedTuple(sites: Array(Site)))
    sites[:sites]
  end

  def site(site_id : String)
    get_request("/be/cp/v2/sites/#{site_id}", Site)
  end

  class Building
    include JSON::Serializable

    property id : String
    property name : String

    @[JSON::Field(key: "siteId")]
    property site_id : String

    property location : Site::Location
  end

  def buildings(site_id : String)
    buildings = get_request("/be/cp/v2/sites/#{site_id}/buildings", NamedTuple(buildings: Array(Building)))
    buildings[:buildings]
  end

  def building(site_id : String, building_id : String)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}", Building)
  end

  class Floor
    include JSON::Serializable

    property id : String
    property name : String

    @[JSON::Field(key: "floorNumber")]
    property floor_number : String

    @[JSON::Field(key: "floorPlanURL")]
    property floor_plan_url : String

    @[JSON::Field(key: "widthDistance")]
    property width_distance : Float64

    @[JSON::Field(key: "lengthDistance")]
    property length_distance : Float64

    # NOTE:: unknown format for referencePoints => Array(?)
  end

  def floors(site_id : String, building_id : String)
    floors = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors", NamedTuple(floors: Array(Building)))
    floors[:floors]
  end

  def floor(site_id : String, building_id : String, floor_id : String)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}", Floor)
  end

  class Area
    include JSON::Serializable

    property id : String
    property name : String
    property length : Float64
    property width : Float64

    @[JSON::Field(key: "centerX")]
    property center_x : Float64

    @[JSON::Field(key: "centerY")]
    property center_y : Float64

    property rotation : Int32
    property frequency : Int32

    @[JSON::Field(key: "deviceIDs")]
    property device_ids : Array(String)

    class Application
      include JSON::Serializable

      @[JSON::Field(key: "areaType")]
      property area_type : String

      @[JSON::Field(key: "applicationType")]
      property application_type : String
    end

    property applications : Array(Application)

    # Area Polygon positions in meters
    @[JSON::Field(key: "metricPositions")]
    property metric_positions : Array(MetricPositions)

    # Area Polygon Coordinates positions
    @[JSON::Field(key: "geoPositions")]
    property geo_positions : Array(GeoPosition)?
  end

  class FloorAreas
    include JSON::Serializable

    @[JSON::Field(key: "floorId")]
    property floor_id : String
    property areas : Array(Area)
  end

  def building_areas(site_id : String, building_id : String)
    floors = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/areas", NamedTuple(
      floorsAreas: FloorAreas
    ))
    floors[:floorsAreas]
  end

  def areas(site_id : String, building_id : String, floor_id : String)
    areas = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}/areas", NamedTuple(
      areas: Array(Area)
    ))
    areas[:areas]
  end

  def area(site_id : String, building_id : String, floor_id : String, area_id : String)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}/areas/#{area_id}", Area)
  end

  class Handler
    include JSON::Serializable

    property id : String
    property token : String

    @[JSON::Field(key: "thirdPartyAppID")]
    property app_id : UInt32

    @[JSON::Field(key: "endPoint")]
    property end_point : String
  end

  def handlers
    handlers = get_request("/be/cp/v2/resources/handlers", NamedTuple(
      handlers: Array(Handler)
    ))
    handlers[:handlers]
  end

  class Subscription
    include JSON::Serializable

    property id : String
    property token : String
    property started : Bool
    property endpoint : String
    property uri : String

    @[JSON::Field(key: "notificationType")]
    property notification_type : String

    @[JSON::Field(key: "subscriptionType")]
    property subscription_type : String
  end

  enum NotificationType
    Counting
    Traffic
  end

  def subscribe(handler_uri : String, auth_token : String = UUID.random.to_s, events : NotificationType = NotificationType::Counting)
    # Ensure the handler is a valid URI
    URI.parse handler_uri

    # Encode the handler
    handler_uri = URI.encode_www_form handler_uri

    token = get_token
    response = post("/be/cp/v2/telemetry/subscriptions",
      body: "subscriptionType=PUSH&notificationType=#{events.to_s.upcase}&endpoint=#{handler_uri}&token=#{auth_token}",
      headers: {
        "Content-Type"  => "application/x-www-form-urlencoded",
        "Accept" => "application/json",
        "Authorization" => token
      }
    )

    body = response.body
    logger.debug { "received login response: #{body}" }

    if response.success?
      Subscription.from_json(body.not_nil!)
    else
      logger.error "authentication failed with HTTP #{response.status_code}"
      raise "failed to obtain access token"
    end
  end

  def subscriptions
    get_request("/be/cp/v2/telemetry/subscriptions", Array(Subscription))
  end

  def delete_subscription(id : String)
    token = get_token
    delete("/be/cp/v2/telemetry/subscriptions/#{id}",
      headers: {
        "Accept" => "application/json",
        "Authorization" => token
      }
    ).success?
  end

  def update_subscription(id : String, started : Bool = true)
    token = get_token
    patch("/be/cp/v2/telemetry/subscriptions/#{id}",
      body: "started=#{started}",
      headers: {
        "Content-Type"  => "application/x-www-form-urlencoded",
        "Accept" => "application/json",
        "Authorization" => token
      }
    ).success?
  end

  # TODO:: this data is posted to the subscription endpoint
  # we need to implement webhooks for this to work properly
  class CountUpdate
    include JSON::Serializable

    @[JSON::Field(key: "areaId")]
    property area_id : String
    property devices : Array(String)

     @[JSON::Field(key: "type")]
    property event_type : String
    property timestamp : UInt64
    property count : Int32
  end

  def update_count(count_json : String)
    count = CountUpdate.from_json(count_json)
    self["area_#{count.area_id}"] = count.count
  end
end
