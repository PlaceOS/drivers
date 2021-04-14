require "http/client"

class Place::DeskBookingWebhook < PlaceOS::Driver
  descriptive_name "Desk Booking Webhook"
  generic_name :DeskBookingWebhook
  description "sends a webhook with booking information as it changes"

  accessor staff_api : StaffAPI_1

  default_settings({
    post_uri: "https://remote-server/path",
    zone_ids: ["zone-id"], # list of zone_ids to monitor

    custom_headers: {
      "API_KEY" => "123456",
    },

    # how many days from now do we want to send
    days_from_now: 14,

    booking_category: "desk",

    # Note: only use metadata_key and mapped_id_key if we need to map BookingUpdate.resource_id to another value
    metadata_key: "desks", # e.g. metadata_key would be "desks" for below example
    mapped_id_key: nil, # e.g. mapped_id_key would be "other_id" for below example
    # e.g. metadata response for /api/engine/v2/metadata/zone-123
    # {
    #   desks: { # metadata_key
    #     description: "blah",
    #     details: {
    #       {id: "desk-1", name: "Desk 1", bookable: true, other_id: "d-1"},
    #       {id: "desk-1", name: "Desk 2", bookable: true, other_id: "d-2"}
    #     }
    #   },
    #   other_metadata_key: {description: "blah2", details: {}}
    # }

    debug: false
  })

  @time_period : Time::Span = 14.days
  @booking_category : String = "desk"
  @custom_headers = {} of String => String
  @zone_ids = [] of String
  @post_uri = ""
  @debug : Bool = false

  def on_load
    monitor("staff/booking/changed") do |_subscription, booking_update|
      logger.debug { "received booking changed event #{booking_update}" }
      process_update(booking_update)
    end
    on_update
  end

  def on_update
    @post_uri = setting(String, :post_uri)
    @zone_ids = setting(Array(String), :zone_ids)
    @custom_headers = setting(Hash(String, String), :custom_headers)
    @time_period = setting(Int32, :days_from_now).days
    @booking_category = setting(String, :booking_category)
    @debug = setting(Bool, :debug)
  end

  struct BookingUpdate
    include JSON::Serializable

    property action : String
    property id : Int64
    property booking_type : String
    property booking_start : Int64
    property booking_end : Int64
    property timezone : String?
    property resource_id : String
    property user_id : String
    property user_email : String
    property user_name : String
    property zones : Array(String)
    property title : String
    property checked_in : Bool?
    property description : String
  end

  private def process_update(json)
    update = BookingUpdate.from_json(json)
    # Only do something if the update is for a zone specified in settings(:zone_ids)
    return unless (@zone_ids & update.zones)
  end

  def fetch_and_post
    period_start = Time.utc.to_unix
    period_end = @time_period.from_now.to_unix
    payload = staff_api.query_bookings(@booking_category, period_start, period_end, @zone_ids).get.to_json

    headers = HTTP::Headers.new
    @custom_headers.each { |key, value| headers[key] = value }
    headers["Content-Type"] = "application/json; charset=UTF-8"

    logger.debug { "Posting: #{payload} \n with Headers: #{headers}" } if @debug
    response = HTTP::Client.post @post_uri, headers, body: payload
    raise "Request failed with #{response.status_code}: #{response.body}" unless response.status_code < 300
    "#{response.status_code}: #{response.body}"
  end
end
