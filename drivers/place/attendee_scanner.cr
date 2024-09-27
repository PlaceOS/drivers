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
        sys = system(system_id)
        if sys.exists?(:Booking)
          bookings = sys[:Booking][:bookings].as_a

          bookings.map do |booking|
            domain = booking["host"].as_s.split("@").last

            unless internal_domains.includes?(domain)
              event_start = Time.unix(booking["event_start"].as_i)
              current_date = Time.local

              if event_start.year == current_date.year &&
                 event_start.month == current_date.month &&
                 (event_start.day == current_date.day || event_start.day == current_date.day + 1)
                booking_id = booking["id"].as_i64
                event_id = booking["event_id"].as_s
                
                attendees = booking["attendees"].as_a
                attendee_emails = attendees.map { |attendee| attendee.as_h.["email"].as_s }
                
                event = staff_api.get_event(event_id: event_id, system_id: system_id).get
                ical_uid = event["ical_uid"].as_s

                calendar_bookings = staff_api.query_bookings(event_id: event_id, ical_uid: ical_uid).get

                external_attendees = [] of JSON::Any

                calendar_bookings.as_a.each do |calendar_booking|
                  calendar_booking
                    .as_h
                    .["attendees"]
                    .as_a
                    .map do |attendee|
                      unless attendee_emails.includes?(attendee.as_h.["email"].as_s)
                        external_attendees.push(attendee)

                        staff_api.create_booking(event_id: event_id, ical_uid: ical_uid)
                      end
                    end
                end

                meetings.push({"id" => booking["id"], "event_id" => booking["event_id"], "external_attendees" => JSON::Any.new(external_attendees)})
              end
            end
          end
        end
      end
    end

    meetings
  end
end
