require "http/client"
require "placeos"

class Place::DeskBookingWebhook < PlaceOS::Driver
  descriptive_name "Desk Booking Webhook"
  generic_name :DeskBookingWebhook
  description "sends a webhook with booking information as it changes"

  accessor staff_api : StaffAPI_1

  default_settings({
    booking_category: "desk",
    zone_ids: ["zone-id"], # list of zone_ids to monitor

    post_uri: "https://remote-server/path",
    custom_headers: {
      "API_KEY" => "123456",
    },

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

  @booking_category : String = "desk"
  @zone_ids = [] of String
  @post_uri = ""
  @custom_headers = {} of String => String
  @metadata_key : String = "desks"
  @mapped_id_key : String? = nil
  @debug : Bool = false

  def on_load
    monitor("staff/booking/changed") do |_subscription, booking_update|
      process_update(booking_update)
    end
    on_update
  end

  def on_update
    @booking_category = setting(String, :booking_category)
    @zone_ids = setting(Array(String), :zone_ids)
    @post_uri = setting(String, :post_uri)
    @custom_headers = setting(Hash(String, String), :custom_headers)
    @metadata_key = setting(String, :metadata_key)
    @mapped_id_key = setting?(String, :mapped_id_key)
    @custom_headers = setting(Hash(String, String), :custom_headers)
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
    property process_state : String?
    property last_changed : Int64?
    property approver_name : String?
    property approver_email : String?
    property title : String
    property checked_in : Bool?
    property description : String
    property ext_data : JSON::Any?
    property booked_by_email : String
    property booked_by_name : String
  end

  def process_update(update_json : String)
    update = BookingUpdate.from_json(update_json)
    # Only do something if the update is for the booking_type and zones specified in the settings

    return if update.booking_type != @booking_category || (@zone_ids & update.zones).empty?

    logger.debug { "received update #{update}" } if @debug

    headers = HTTP::Headers.new
    @custom_headers.each { |key, value| headers[key] = value }
    headers["Content-Type"] = "application/json; charset=UTF-8"
    # If @mapped_id_key is present, then we need to map resource ids before sending the payload
    # Otherwise, just use update_json unmodified as the payload
    payload = @mapped_id_key ? map_resource_id(update).to_json : update_json

    logger.debug { "Posting: #{payload} \n with Headers: #{headers}" } if @debug
    response = HTTP::Client.post @post_uri, headers, body: payload
    summary = "#{response.status_code}: #{response.body}"
    raise "Request failed with #{summary}" unless response.status_code < 300
    logger.debug { summary } if @debug
    summary
  end

  alias Metadata = Hash(String, PlaceOS::Client::API::Models::Metadata)

  private def map_resource_id(update : BookingUpdate)
    metadata = Metadata.from_json(staff_api.metadata(update.zones[0], @metadata_key).get.to_json)[@metadata_key]
    matching_resource = metadata.details.as_a.find(&.["id"].==(update.resource_id)).not_nil!
    # If there is a mapped id value, use that for update.resource_id
    # Otherwise, just use the current update.resource_id
    if mapped_id_value = matching_resource[@mapped_id_key.not_nil!]?
      update.resource_id = mapped_id_value.as_s
    end
    update
  end
end
