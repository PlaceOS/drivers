require "placeos-driver"
require "bright"

class GoBright::BookingAPI < PlaceOS::Driver
  descriptive_name "GoBright API Gateway"
  generic_name :Occupancy
  uri_base "https://example.gobright.cloud"

  alias Client = ::Bright::Client

  default_settings({api_key: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"})

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    base_url = config.uri.not_nil!.to_s
    api_key = setting(String, :api_key)

    @client = Client.new(base_url: base_url, api_key: api_key)
  end

  def bookings?(start_date : String, end_date : String, location_ids : Array(String) = [] of String, space_ids : Array(String) = [] of String, included_submodels : String? = nil, paging_skip : Int32 = 10, paging_take : Int32 = 10)
    self["bookings_#{start_date}_#{end_date}"] =  client.bookings.get(start_date, end_date, location_ids, space_ids, included_submodels, paging_skip, paging_take)
  end

  def booking_occurrences?(start_date : String, end_date : String, location_ids : Array(String) = [] of String, space_ids : Array(String) = [] of String, included_submodels : String? = nil, paging_skip : Int32 = 10, paging_take : Int32 = 10, continuation_token : String? = nil)
    self["booking_#{start_date}_#{end_date}_occurrences"] = client.bookings.get_occurrences(start_date, end_date, location_ids, space_ids, included_submodels, paging_skip, paging_take, continuation_token)
  end

  def create_booking(subject : String, start_date : String, end_date : String, time_zone : String, space_ids : Array(String))
    booking = Bright::Models::Booking.from_json <<-JSON
      {
        "bookingType": 2,
        "spaceIds": [],
        "start": "string",
        "startIanaTimeZone": "string",
        "end": "string",
        "endIanaTimeZone": "string",
        "periodStartIanaTimeZone": "string",
        "periodEndIanaTimeZone": "string",
        "subject": "string"
      }
    JSON

    booking.subject = subject
    booking.start_date = start_date
    booking.end_date = end_date
    booking.start_iana_time_zone = time_zone
    booking.end_iana_time_zone = time_zone
    booking.period_start_iana_time_zone = time_zone
    booking.period_end_iana_time_zone = time_zone
    booking.space_ids = space_ids

    self["booking"] = client.bookings.create(booking)
  end

  def update_booking(composed_id : String, subject : String, start_date : String, end_date : String, time_zone : String, space_ids : Array(String))
    booking = Bright::Models::Booking.from_json <<-JSON
      {
        "bookingType": 2,
        "spaceIds": [],
        "start": "string",
        "startIanaTimeZone": "string",
        "end": "string",
        "endIanaTimeZone": "string",
        "periodStartIanaTimeZone": "string",
        "periodEndIanaTimeZone": "string",
        "subject": "string"
      }
    JSON

    booking.composed_id = composed_id
    booking.subject = subject
    booking.start_date = start_date
    booking.end_date = end_date
    booking.start_iana_time_zone = time_zone
    booking.end_iana_time_zone = time_zone
    booking.period_start_iana_time_zone = time_zone
    booking.period_end_iana_time_zone = time_zone
    booking.space_ids = space_ids

    self["booking#{composed_id}"] = client.bookings.update(booking)
  end

  def delete_booking(booking_id : String)
    self["booking#{booking_id}"] = client.bookings.delete(booking_id)
  end

  def locations?(paging_skip : Int32 = 10, paging_take : Int32 = 10)
    self["locations"] = client.locations.get(paging_skip, paging_take)
  end

  def occupancy?(filter_location_id : String, filter_space_type : Int32? = nil, paging_skip : Int32 = 10, paging_take : Int32 = 10)
    self["occupancy_#{filter_location_id}"] = client.occupancy.get(filter_location_id, filter_space_type, paging_skip, paging_take)
  end

  def spaces?(space_types : Int32 = 0, location_id : String? = nil, included_submodels : String? = nil, paging_skip : Int32 = 10, paging_take : Int32 = 10)
    self["spaces_#{space_types}_location_#{location_id}"] = client.spaces.get(space_types, location_id, included_submodels, paging_skip, paging_take)
  end
end
