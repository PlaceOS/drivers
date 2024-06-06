require "placeos-driver"
require "placeos-driver/interface/mailer"
require "place_calendar"

class Place::AutoRelease < PlaceOS::Driver
  descriptive_name "PlaceOS Auto Release"
  generic_name :AutoRelease
  description %(emails visitors to confirm automatic release of their booking when they have indicated they are not on-site and releases the booking if they do not confirm)

  # time_window_hours: The number of hours to check for bookings pending release
  #
  # release_locations: Locations to release bookings for
  # available locations:
  # - wfh: Work From Home
  # - aol: Away on Leave
  # - wfo: Work From Office
  default_settings({
    timezone:          "GMT",
    send_emails:       "*/5 * * * *",
    email_template:    "auto_release",
    time_window_hours: 4,
    release_locations: ["wfh", "aol"],
  })

  accessor staff_api : StaffAPI_1

  getter building_id : String { get_building_id.not_nil! }

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

    @send_emails = setting?(String, :send_emails).presence
    @email_template = setting?(String, :email_template) || "auto_release"

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @release_locations = setting?(Array(String), :release_locations) || ["wfh"]
    @auto_release = setting?(AutoReleaseConfig, :auto_release) || AutoReleaseConfig.new

    schedule.clear

    # find bookins pending release
    schedule.every(5.minutes) { pending_release }

    # release bookings
    schedule.every(1.minute) { release_bookings }

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

  @[Security(Level::Support)]
  def enabled? : Bool
    if !@auto_release.resources.empty? &&
       (@auto_release.time_after > 0)
      true
    else
      false
    end
  end

  @[Security(Level::Support)]
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

    logger.debug { "found #{results.size} pending bookings" }

    self[:pending_bookings] = results
  rescue error
    logger.warn(exception: error) { "unable to obtain list of bookings" }
    self[:pending_bookings] = [] of Booking
  end

  @[Security(Level::Support)]
  def get_user_preferences?(user_id : String)
    user = staff_api.user(user_id).get

    work_preferences = Array(WorktimePreference).from_json user.as_h["work_preferences"].to_json
    work_overrides = Hash(String, WorktimePreference).from_json user.as_h["work_overrides"].to_json

    {work_preferences: work_preferences, work_overrides: work_overrides}
  rescue error
    logger.warn(exception: error) { "unable to obtain user work location" }
    nil
  end

  @[Security(Level::Support)]
  def pending_release
    results = [] of Booking
    bookings = get_pending_bookings

    bookings.each do |booking|
      if preferences = get_user_preferences?(booking.user_id)
        day_of_week = Time.unix(booking.booking_start).day_of_week.value + 1
        event_time = Time.unix(booking.booking_start).hour + (Time.unix(booking.booking_start).minute / 60.0)

        if (override = preferences[:work_overrides][Time.unix(booking.booking_start).to_s(format: "%F")]?) &&
           (override.start_time < event_time && override.end_time > event_time) &&
           (@release_locations.includes? override.location)
          results << booking
        elsif (preference = preferences[:work_preferences].find { |pref| pref.day_of_week == day_of_week }) &&
              (preference.start_time < event_time && preference.end_time > event_time) &&
              (@release_locations.includes? preference.location)
          results << booking
        end
      end
    end

    logger.debug { "found #{results.size} bookings pending release" }

    self[:pending_release] = results
  end

  def release_bookings
    released_bookings = [] of Booking
    bookings = Array(Booking).from_json self[:pending_release].to_json

    bookings.each do |booking|
      if @auto_release.time_after > 0 && Time.utc.to_unix - booking.booking_start > @auto_release.time_after / 60
        logger.debug { "rejecting booking #{booking.id} as it is within the time_after window" }
        staff_api.reject(booking.id).get
        released_bookings << booking
      end
    end

    logger.debug { "released #{released_bookings.size} bookings" }

    released_bookings
  rescue error
    logger.warn(exception: error) { "unable to release bookings" }
    [] of Booking
  end

  @[Security(Level::Support)]
  def send_release_emails
    emailed_booking_ids = [] of Int64
    bookings = self[:pending_release]? ? Array(Booking).from_json(self[:pending_release].to_json) : [] of Booking

    previously_emailed = self[:emailed_booking_ids]? ? Array(Int64).from_json(self[:emailed_booking_ids].to_json) : [] of Int64
    # remove previously emailed bookings that are no longer pending release
    previously_emailed -= previously_emailed - bookings.map(&.id)
    # add previously emailed bookings that are still pending release
    emailed_booking_ids += previously_emailed

    bookings.each do |booking|
      next if previously_emailed.includes? booking.id

      if @auto_release.time_before > 0 &&
         (booking.booking_start - Time.utc.to_unix < @auto_release.time_before / 60) &&
         (Time.utc.to_unix - booking.booking_start < @auto_release.time_after / 60)
        logger.debug { "sending release email to #{booking.user_email} for booking #{booking.id} as it is withing the time_before window" }
        begin
          mailer.send_template(
            to: booking.user_email,
            template: {@email_template, "auto_release"},
            args: {
              booking_id:    booking.id,
              user_email:    booking.user_email,
              user_name:     booking.user_name,
              booking_start: booking.booking_start,
              booking_end:   booking.booking_end,
            })
          emailed_booking_ids << booking.id
        rescue error
          logger.warn(exception: error) { "failed to send release email to #{booking.user_email}" }
        end
      end
    end
    self[:emailed_booking_ids] = emailed_booking_ids
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
