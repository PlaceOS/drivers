module Place; end

require "http/client"

class Place::DeskBookingWebhook < PlaceOS::Driver
  descriptive_name "Desk Booking Webhook"
  generic_name :DeskBookingWebhook
  description %(sends a webhook with booking information as it changes)

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

    # Note: only use metadata_key and mapped_id_key if we need to map interally used resource_id to another value
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
    #   other_metadata_key: {}
    # }

    debug: false,
  })

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      process_update(payload)
    end
    on_update
  end

  @time_period : Time::Span = 14.days
  @booking_category : String = "desk"
  @custom_headers = {} of String => String
  @zone_ids = [] of Array(String)
  @post_uri = ""
  @debug : Bool = false

  def on_update
    @post_uri = setting(String, :post_uri)
    @zone_ids = setting(Array(String), :zone_ids)
    @custom_headers = setting(Hash(String, String), :custom_headers)
    @time_period = setting(Int32, :days_from_now).days
    @booking_category = setting(String, :booking_category)
    @debug = setting(Bool, :debug)
  end

  private def process_update(update)
    # Only do something if the update is for a zone specified in settings(:zone_ids)
    return unless (@zone_ids && update[:zones]).present?
  end

  def fetch_and_post
    period_start = Time.utc.to_unix
    period_end = @time_period.from_now.to_unix
    zones = [@building]
    payload = staff_api.query_bookings(@booking_category, period_start, period_end, zones).get.to_json

    headers = HTTP::Headers.new
    @custom_headers.each { |key, value| headers[key] = value }
    headers["Content-Type"] = "application/json; charset=UTF-8"

    logger.debug { "Posting: #{payload} \n with Headers: #{headers}" } if @debug
    response = HTTP::Client.post @post_uri, headers, body: payload
    raise "Request failed with #{response.status_code}: #{response.body}" unless response.status_code < 300
    "#{response.status_code}: #{response.body}"
  end
end
