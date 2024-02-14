require "placeos-driver"
require "placeos-driver/interface/mailer"
require "place_calendar"

class Place::AutoRelease < PlaceOS::Driver
  descriptive_name "PlaceOS Auto Release"
  generic_name :AutoRelease
  description %(emails visitors to confirm automatic release of their booking when they have indicated they are not on-site and releases the booking if they do not confirm)

  default_settings({
    timezone:       "GMT",
    send_emails:    "15 */1 * * *",
    email_template: "auto_release",
    # release_url: "https://example.com/release",
    time_window_hours: 1,
    release_locations: ["wfh"],
  })

  accessor staff_api : StaffAPI_1

  getter building_id : String { get_building_id.not_nil! }
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    on_update
  end

  @time_zone : Time::Location = Time::Location.load("GMT")

  @auto_release_emails_sent : UInt64 = 0_u64
  @auto_release_email_errors : UInt64 = 0_u64

  @email_template : String = "auto_release"
  @send_emails : String? = nil

  @time_window_hours : Int32 = 1
  @release_locations : Array(String) = ["wfh"]
  @auto_release : AutoReleaseConfig = AutoReleaseConfig.new

  def on_update
    @building_id = nil
    @systems = nil

    @send_emails = setting?(String, :send_emails).presence
    @email_template = setting?(String, :email_template) || "auto_release"

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @release_locations = setting?(Array(String), :release_locations) || ["wfh"]
    @auto_release = setting?(AutoReleaseConfig, :auto_release) || AutoReleaseConfig.new

    schedule.clear

    # used to detect changes in building configuration
    schedule.every(1.hour) { @systems = get_systems_list.not_nil! }

    # The search
    schedule.every(5.minutes) { find_and_release_bookings }

    if emails = @send_emails
      schedule.cron(emails, @time_zone) { send_release_emails }
    end
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  # Grabs the list of systems in the building
  def get_systems_list
    staff_api.systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  rescue error
    logger.warn(exception: error) { "unable to obtain list of systems in the building" }
    nil
  end

  @[Security(Level::Support)]
  def enabled? : Bool
    if !@auto_release.resources.empty? &&
       ((@auto_release.time_before > 0) || (@auto_release.time_after > 0))
      true
    else
      false
    end
  end

  def get_pending_bookings : Array(Booking)
    results = [] of Booking

    @auto_release.resources.each do |type|
      bookings = Array(Booking).from_json staff_api.query_bookings(
        type: type,
        period_start: Time.utc.to_unix,
        period_end: (Time.utc + @time_window_hours.hours).to_unix,
        zones: [building_id],
        checked_in: false,
      ).get.to_json
      results += bookings
    end

    self[:pending_release] = results
  rescue error
    logger.warn(exception: error) { "unable to obtain list of bookings" }
    [] of Booking
  end

  @[Security(Level::Support)]
  def find_and_release_bookings : Hash(String, Array(PlaceCalendar::Event))
    results = {} of String => Array(PlaceCalendar::Event)

    return results unless enabled?

    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        sys = system(system_id)
        if sys.exists?("Bookings", 1)
          if bookings = sys.get("Bookings", 1).status?(Array(PlaceCalendar::Event), "bookings")
            bookings.select! { |event| event.event_start < Time.utc + @time_window_hours.hours }
            bookings.select! do |event|
              if event_end = event.event_end
                event_end > Time.utc
              else
                true
              end
            end

            users = {} of String => JSON::Any?
            bookings.each do |event|
              next unless event_id = event.id
              metadata = staff_api.metadata(event_id).get.as_h
              if linked_bookings = metadata["linked_bookings"]?
                linked_bookings.as_a.each do |linked_booking|
                  if !linked_booking.as_h["checked_in"]? &&
                     @auto_release.resources.includes? linked_booking.as_h["type"] &&
                                                       (user_id = linked_booking.as_h["user_id"]?)
                    users[event_id] = staff_api.user(user_id).get
                  end
                end
              end
            end

            bookings.select! do |event|
              if user = users[event.id]?
                work_preferences = Array(WorktimePreference).from_json user.as_h["work_preferences"].to_json
                work_overrides = Hash(String, WorktimePreference).from_json user.as_h["work_overrides"].to_json

                if work_preferences.empty? && work_overrides.empty?
                  false
                else
                  day_of_week = event.event_start.day_of_week.value + 1
                  event_time = event.event_start.hour + (event.event_start.minute / 60.0)

                  if (preference = work_preferences.find { |pref| pref.day_of_week == day_of_week })
                    (preference.start_time > event_time || preference.end_time < event_time) &&
                      (@release_locations.includes? preference.location)
                  elsif (override = work_overrides[event.event_start.date.to_s])
                    (override.start_time > event_time || override.end_time < event_time) &&
                      (@release_locations.includes? override.location)
                  else
                    false
                  end
                end
              else
                false
              end
            end

            released_bookings = [] of String
            bookings.each do |event|
              next unless event_id = event.id
              if config = @auto_release
                if (time_before = config.time_before) && time_before > 0
                  staff_api.reject(event_id).get
                  released_bookings << event_id
                elsif (time_after = config.time_after) && time_after > 0
                  staff_api.reject(event_id).get
                  released_bookings << event_id
                end
              end
            end
            bookings.select! { |event| !released_bookings.includes? event.id }

            results[system_id] = bookings unless bookings.empty?
          end
        end
      end
    end

    self[:pending_release] = results
  end

  @[Security(Level::Support)]
  def send_release_emails
    bookings = Hash(String, Array(PlaceCalendar::Event)).from_json self[:pending_release].to_json
    bookings.each do |sys, events|
      events.each do |event|
        begin
          mailer.send_template(
            to: event.host,
            template: {@email_template, "auto_release"},
            args: {
              email:    event.host,
              event_id: event.id,
              ical_uid: event.ical_uid,
            })
        rescue error
          logger.warn(exception: error) { "failed to send release email to #{event.host}" }
        end
      end
    end
  end

  # time_before and time_after are in minutes
  record AutoReleaseConfig, time_before : Int64 = 0, time_after : Int64 = 0, resources : Array(String) = [] of String do
    include JSON::Serializable
  end

  # day_of_week: Index of the day of the week. `0` being Sunday
  # start_time: Start time of work hours. e.g. `7.5` being 7:30AM
  # end_time: End time of work hours. e.g. `18.5` being 6:30PM
  # location: Name of the location the work is being performed at
  record WorktimePreference, day_of_week : Int64, start_time : Float64, end_time : Float64, location : String = "" do
    include JSON::Serializable
  end

  struct Booking
    include JSON::Serializable

    property id : Int64

    property user_id : String
    property user_email : String
    property user_name : String
    property asset_id : String
    property zones : Array(String)
    property booking_type : String

    property booking_start : Int64
    property booking_end : Int64

    property timezone : String?
    property title : String?
    property description : String?

    property checked_in : Bool
    property rejected : Bool
    property approved : Bool

    property approver_id : String?
    property approver_email : String?
    property approver_name : String?

    property booked_by_id : String
    property booked_by_email : String
    property booked_by_name : String

    property process_state : String?
    property last_changed : Int64?
    property created : Int64?
  end
end
