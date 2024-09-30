require "placeos-driver"
require "json"

class Place::AttendeeScanner < PlaceOS::Driver
  descriptive_name "PlaceOS Room Events"
  generic_name :AttendeeScanner

  accessor staff_api : StaffAPI_1

  default_settings({
    internal_domains: [] of String,
  })

  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }
  getter internal_domains : Array(String) = [] of String

  def on_update
    @internal_domains = setting(Array(String), :internal_domains)
  end

  # Grabs the list of systems in the building
  def get_systems_list
    building_id = system[:Location].building_id.get
    system["StaffAPI"].systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  rescue error
    logger.warn(exception: error) { "unable to obtain list of systems in the building" }
    nil
  end

  # Lists external guests based on email domains
  def list_external_guests
    meetings = [] of Hash(String, JSON::Any)

    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        period_start = Time.local.to_unix
        period_end = Time.local.to_unix + 86400

        events = staff_api.query_events(period_start, period_end, systems: [system_id]).get

        events.each do |event|
          domain = event.as_h.["host"].as_s.split("@").last

          unless internal_domains.includes?(domain)
            event_id = event.as_h.["id"].as_s
            ical_uid = event.as_h.["ical_uid"].as_s

            bookings = staff_api.query_bookings(event_id: event_id, ical_uid: ical_uid).get

            attendee_emails = event["attendees"].as_a.map do |attendee|
              attendee.as_h.["email"].as_s
            end

            bookings.as_a.each do |booking|
              booking.as_h.["attendees"].as_a.each do |attendee|
                unless attendee_emails.includes?(attendee.as_h.["email"].as_s)
                  staff_api.create_booking(
                    booking_type: "",
                    asset_id: "",
                    user_id: "",
                    user_email: "",
                    user_name: "",
                    zones: [] of String,
                    booking_start: nil,
                    booking_end: nil,
                    checked_in: false,
                    approved: nil,
                    title: nil,
                    description: nil,
                    time_zone: nil,
                    extension_data: nil,
                    utm_source: nil,
                    limit_override: nil,
                    event_id: nil,
                    ical_uid: nil,
                    attendees: nil
                  ).get
                end
              end
            end
          end
        end
      end
    end

    meetings
  end
end
