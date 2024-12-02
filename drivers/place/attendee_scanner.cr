require "placeos-driver"
require "place_calendar"

class Place::AttendeeScanner < PlaceOS::Driver
  descriptive_name "PlaceOS Room Events"
  generic_name :AttendeeScanner

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  default_settings({
    internal_domains: ["comment.out", "use authority / domain email_domains by preference"],
  })

  getter internal_domains : Array(String) = [] of String

  def on_update
    # TODO:: use authority email_domains by
    @internal_domains = setting(Array(String), :internal_domains).map!(&.strip.downcase)
  end

  # Grabs the list of systems in the building
  def systems
    locations.systems.get.as_h.transform_values(&.as_a.map(&.as_s))
  end

  def building_id
    locations.building_id.get.as_s
  end

  alias Event = PlaceCalendar::Event
  alias Attendee = PlaceCalendar::Event::Attendee

  record Guest, zones : Tuple(String, String), system_id : String, details : Attendee, event : Event do
    include JSON::Serializable
  end

  def externals_in_bookings
    building = building_id
    externals = [] of Guest

    now = Time.utc

    # Find all the guests
    systems.each do |level_id, system_ids|
      zones = {building, level_id}

      system_ids.each do |system_id|
        sys = system(system_id)
        if sys.exists?("Bookings", 1)
          events = sys.get("Bookings", 1).status(Array(Event), :bookings) rescue [] of Event
          events.each do |event|
            externals.concat(event.attendees.reject { |attendee|
              internal_domains.find { |domain| attendee.email.ends_with? domain }
            }.map { |attendee|
              Guest.new(zones, system_id, attendee, event)
            })
          end
        end
      end
    end

    externals
  end

  # Lists external guests based on email domains
  def list_external_guests
    values = [] of Hash(String, JSON::Any)

    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        period_start = Time.local.to_unix
        period_end = Time.local.to_unix + 86400

        events = staff_api.query_events(period_start, period_end, systems: [system_id]).get

        events.as_a.each do |event|
          domain = event.as_h.["host"].as_s.split("@").last

          unless internal_domains.includes?(domain)
            event_id = event.as_h.["id"].as_s
            ical_uid = event.as_h.["ical_uid"].as_s

            bookings = staff_api.query_bookings(event_id: event_id, ical_uid: ical_uid).get

            attendee_emails = event["attendees"].as_a.map do |attendee|
              attendee.as_h.["email"].as_s
            end

            bookings.as_a.each do |booking|
              booking = booking.as_h

              booking.["attendees"].as_a.each do |attendee|
                attendee_email = attendee.as_h.["email"].as_s

                unless attendee_emails.includes?(attendee_email)
                  staff_api.create_booking(
                    booking_type: "visitor",
                    asset_id: attendee_email,
                    user_id: attendee_email,
                    user_email: attendee_email,
                    user_name: booking["user_name"].as_s,
                    zones: booking["zones"].as_a?,
                    booking_start: booking["booking_start"].as_s?,
                    booking_end: booking["booking_end"].as_s?,
                    checked_in: booking["checked_in"].as_bool?,
                    approved: booking["approved"].as_bool?,
                    title: booking["title"].as_s?,
                    description: booking["description"].as_s?,
                    time_zone: booking["time_zone"].as_s?,
                    extension_data: booking["extension_data"]?,
                    utm_source: nil,
                    limit_override: nil,
                    event_id: event_id,
                    ical_uid: ical_uid,
                    attendees: nil
                  ).get

                  values.push({
                    "event_id" => event.as_h.["id"],
                    "ical_uid" => event.as_h.["ical_uid"],
                    "booking"  => JSON::Any.new(booking),
                  })
                end
              end
            end
          end
        end
      end
    end

    values
  end
end
