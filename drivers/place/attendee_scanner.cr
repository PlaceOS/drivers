require "placeos-driver"
require "json"

class Place::AttendeeScanner < PlaceOS::Driver
  descriptive_name "PlaceOS Room Events"
  generic_name :AttendeeScanner

  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

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
    guests = [] of Hash(String, JSON::Any)

    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        sys = system(system_id)
        if sys.exists?(:Booking)
          bookings = sys[:Booking][:bookings].as_a

          bookings.map do |booking|
            unless booking["host"].as_s.includes?("place.technology")
              event_start = Time.unix(booking["event_start"].as_i)
              current_date = Time.local

              if event_start.year == current_date.year &&
                 event_start.month == current_date.month &&
                 event_start.day == current_date.day
                booking["attendees"].as_a.map do |attendee|
                  guests.push(attendee.as_h)
                end
              end
            end
          end
        end
      end
    end

    guests
  end
end
