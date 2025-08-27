require "placeos-driver"
require "place_calendar"

class Zoom::BookingConverter < PlaceOS::Driver
  descriptive_name "Convert Zoom Bookings to PlaceOS Calendar Events"
  generic_name :Bookings
  description %(Retrieves bookings from Zoom CSAPI Module and exposes them as PlaceOS Calendar events)

  # default_settings({
  # })

  accessor zoom_csapi : ZoomCSAPI_1

  def on_load
    on_update
  end

  def on_update
    subscriptions.clear
    subscription = system.subscribe(:ZoomCSAPI_1, :BookingsListResult) do |_subscription, new_data|
      zoom_bookings_list = Array(JSON::Any).from_json(new_data)
      logger.debug { "Detected changed in Zoom Bookings List: : #{zoom_bookings_list.inspect}" }
      expose_bookings(zoom_bookings_list)
    end
    # ensure current booking is updated at the start of every minute
    # rand spreads the load placed on redis
    schedule.cron("* * * * *") do
      schedule.in(rand(1000).milliseconds) do
        if list = self[:bookings]?
          determine_current_booking(list.as_a)
          determine_next_booking(list.as_a)
        end
      end
    end
  end

  private def expose_bookings(zoom_bookings_list : Array(JSON::Any))
    placeos_bookings = [] of  Hash(String, Array(Bool) | Bool | Int64 | String | Nil)
    zoom_bookings_list.each do |zoom_booking|
      placeos_bookings << convert_booking(zoom_booking)
    end
    self[:bookings] = placeos_bookings
  end

  private def convert_booking(zoom_booking : JSON::Any)
    {
        "title"       => zoom_booking["meetingName"].as_s,
        "body"        => zoom_booking["location"].as_s,
        "location"    => zoom_booking["location"].as_s,
        "event_start" => Time.parse_rfc3339(zoom_booking["startTime"].as_s).to_unix,
        "event_end"   => Time.parse_rfc3339(zoom_booking["endTime"].as_s).to_unix,
        "id"          => zoom_booking["meetingNumber"].as_s,

        "recurring_event_id" => nil,
        "attendees" => [] of Bool,
        "attachments" => [] of Bool,
        "timezone" => nil,
        "recurring" => false,
        "created" => nil,
        "updated" => nil,
        "recurrence" => nil,
        "status" => nil,
        "creator" => nil,
        "ical_uid" => nil,
        "private" => false,
        "all_day" => false
    }
  end

  private def determine_current_booking(bookings : Array(JSON::Any))
    if bookings.empty?
      self[:current_booking] = nil
      self[:booking_in_progress] = false
      return
    end
    current_time = Time.utc.to_unix
    current_booking = bookings.find do |booking|
      booking["event_start"].as_i64 <= current_time && booking["event_end"].as_i64 > current_time
    end
    self[:current_booking] = current_booking || nil
    self[:booking_in_progress] = !current_booking.nil?
  end

  # This assumes the Zoom bookings are sorted by start time, which is still TBD
  private def determine_next_booking(bookings : Array(JSON::Any))
    if bookings.empty?
      self[:next_booking] = nil
      return
    end
    current_time = Time.utc.to_unix
    next_booking = bookings.find do |booking|
      booking["event_start"].as_i64 > current_time
    end
    self[:next_booking] = next_booking || nil
  end
end
