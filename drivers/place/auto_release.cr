require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"

class Place::AutoRelease < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

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
    timezone:          "Australia/Sydney",
    date_time_format:  "%c",
    time_format:       "%l:%M%p",
    date_format:       "%A, %-d %B",
    email_schedule:    "*/5 * * * *",
    email_template:    "auto_release",
    time_window_hours: 4,
    release_locations: ["wfh", "aol"],
  })

  accessor staff_api : StaffAPI_1

  getter building_zone : Zone { get_building_zone?.not_nil! }

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  @auto_release_emails_sent : UInt64 = 0_u64
  @auto_release_email_errors : UInt64 = 0_u64

  @email_template : String = "auto_release"
  @email_schedule : String? = nil

  @time_window_hours : Int32 = 1
  @release_locations : Array(String) = ["wfh"]
  @auto_release : AutoReleaseConfig = AutoReleaseConfig.new

  def on_update
    @building_zone = nil

    @email_schedule = setting?(String, :email_schedule).presence
    @email_template = setting?(String, :email_template) || "auto_release"

    timezone = setting?(String, :timezone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @release_locations = setting?(Array(String), :release_locations) || ["wfh"]
    @auto_release = setting?(AutoReleaseConfig, :auto_release) || AutoReleaseConfig.new

    schedule.clear

    # find bookins pending release
    schedule.every(5.minutes) { pending_release }

    # release bookings
    schedule.every(1.minute) { release_bookings }

    if emails = @email_schedule
      schedule.cron(emails, @timezone) { send_release_emails }
    end
  end

  # Finds the building zone for the current location services object
  def get_building_zone? : Zone?
    zones = Array(Zone).from_json staff_api.zones(tags: "building").get.to_json
    zone_ids = zones.map(&.id)
    zone_id = (zone_ids & system.zones).first
    zones.find { |zone| zone.id == zone_id }
  rescue error
    logger.warn(exception: error) { "unable to determine building zone" }
    nil
  end

  @[Security(Level::Support)]
  def enabled? : Bool
    if !@auto_release.resources.empty? &&
       (@auto_release.time_before > 0 || @auto_release.time_after > 0) &&
       !building_zone.time_location?.nil?
      true
    else
      logger.notice { "auto release is not enabled on zone #{building_zone.id}" }
      logger.debug { "auto release is not enabled on zone #{building_zone.id} due to auto_release.resources being empty" } if @auto_release.resources.empty?
      logger.debug { "auto release is not enabled on zone #{building_zone.id} due to auto_release.time_before and auto_release.time_after being 0" } if @auto_release.time_before.zero? && @auto_release.time_after.zero?
      logger.debug { "auto release is not enabled on zone #{building_zone.id} due to building_zone.time_location being nil" } if building_zone.time_location?.nil?
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
        zones: [building_zone.id],
      ).get.to_json
      results += bookings.select { |booking| !booking.checked_in }
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

  def in_preference_hours?(start_time : Float64, end_time : Float64, event_time : Float64) : Bool
    if start_time < end_time
      start_time < event_time && end_time > event_time
    else
      start_time < event_time || end_time > event_time
    end
  end

  def in_preference?(preference : WorktimePreference, event_time : Float64, locations : Array(String), match_locations : Bool = true) : Bool
    if match_locations
      preference.blocks.any? do |block|
        in_preference_hours?(block.start_time, block.end_time, event_time) &&
          locations.includes? block.location
      end
    else
      preference.blocks.any? do |block|
        in_preference_hours?(block.start_time, block.end_time, event_time) &&
          !locations.includes?(block.location)
      end
    end
  end

  @[Security(Level::Support)]
  def pending_release
    results = [] of Booking
    return results unless enabled?

    bookings = get_pending_bookings

    bookings.each do |booking|
      if preferences = get_user_preferences?(booking.user_id)
        # get the booking start time in the building timezone
        booking_start = Time.unix(booking.booking_start).in building_zone.time_location!

        day_of_week = booking_start.day_of_week.value
        day_of_week = 0 if day_of_week == 7 # Crystal uses 7 for Sunday, but we use 0 (all other days match up)

        # convert unix timestamp to float hours/minutes
        # e.g. 7:30AM = 7.5
        event_time = booking_start.hour + (booking_start.minute / 60.0)

        # exclude overrides with empty time blocks
        overrides = preferences[:work_overrides].select { |_, pref| pref.blocks.size > 0 }

        if (override = overrides[booking_start.to_s(format: "%F")]?) &&
           in_preference?(override, event_time, @release_locations)
          results << booking
        elsif (override = overrides[booking_start.to_s(format: "%F")]?) &&
              in_preference?(override, event_time, @release_locations, false)
        elsif (preference = preferences[:work_preferences].find { |pref| pref.day_of_week == day_of_week }) &&
              in_preference?(preference, event_time, @release_locations)
          results << booking
        end
      end
    end

    logger.debug { "found #{results.size} bookings pending release" }

    self[:pending_release] = results
  end

  def skip_release?(cached_booking : Booking) : Bool
    if (booking_json_any = staff_api.get_booking(cached_booking.id).get) &&
       (booking = Booking.from_json(booking_json_any.to_json))
      booking.checked_in || booking.booking_start != cached_booking.booking_start
    else
      true
    end
  end

  def release_bookings
    released_booking_ids = [] of Int64
    return released_booking_ids unless enabled?

    bookings = self[:pending_release]? ? Array(Booking).from_json(self[:pending_release].to_json) : [] of Booking

    previously_released = self[:released_booking_ids]? ? Array(Int64).from_json(self[:released_booking_ids].to_json) : [] of Int64
    # remove previously released bookings that are no longer pending release
    previously_released -= previously_released - bookings.map(&.id)
    # add previously released bookings that are still pending release
    released_booking_ids += previously_released

    bookings.each do |booking|
      next if previously_released.includes? booking.id

      # convert minutes (time_after) to seconds for comparison with unix timestamps (booking_start)
      if Time.utc.to_unix - booking.booking_start > @auto_release.time_after * 60
        # skip if there's been changes to the cached bookings checked_in status or booking_start time
        next if skip_release?(booking)

        logger.debug { "rejecting booking #{booking.id} as it is within the time_after window" }
        staff_api.reject(booking.id).get
        released_booking_ids << booking.id
      end
    end

    logger.debug { "released #{released_booking_ids.size} bookings" }

    self[:released_booking_ids] = released_booking_ids
  rescue error
    logger.warn(exception: error) { "unable to release bookings" }
    self[:released_booking_ids] = [] of Int64
  end

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(@timezone)
    [
      TemplateFields.new(
        trigger: {@email_template, "auto_release"},
        name: "Auto release booking",
        description: "Notification when a booking is pending automatic release due to user's work location preferences",
        fields: [
          {name: "booking_id", description: "Unique identifier for the booking that may be released"},
          {name: "booking_start", description: "Unix timestamp of when the booking begins"},
          {name: "booking_end", description: "Unix timestamp of when the booking ends"},
          {name: "start_time", description: "Formatted start time (e.g., #{time_now.to_s(@time_format)})"},
          {name: "start_date", description: "Formatted start date (e.g., #{time_now.to_s(@date_format)})"},
          {name: "start_datetime", description: "Formatted start date and time (e.g., #{time_now.to_s(@date_time_format)})"},
          {name: "end_time", description: "Formatted end time (e.g., #{time_now.to_s(@time_format)})"},
          {name: "end_date", description: "Formatted end date (e.g., #{time_now.to_s(@date_format)})"},
          {name: "end_datetime", description: "Formatted end date and time (e.g., #{time_now.to_s(@date_time_format)})"},
          {name: "asset_id", description: "Identifier of the booked resource"},
          {name: "user_id", description: "Identifier of the person who has the booking"},
          {name: "user_email", description: "Email address of the person who has the booking"},
          {name: "user_name", description: "Full name of the person who has the booking"},
          {name: "reason", description: "Title or purpose of the booking"},
          {name: "approver_name", description: "Name of the person who approved the booking"},
          {name: "approver_email", description: "Email of the person who approved the booking"},
          {name: "booked_by_name", description: "Name of the person who made the booking"},
          {name: "booked_by_email", description: "Email of the person who made the booking"},
        ]
      ),
    ]
  end

  @[Security(Level::Support)]
  def send_release_emails
    emailed_booking_ids = [] of Int64
    bookings = self[:pending_release]? ? Array(Booking).from_json(self[:pending_release].to_json) : [] of Booking
    previously_released = self[:released_booking_ids]? ? Array(Int64).from_json(self[:released_booking_ids].to_json) : [] of Int64

    previously_emailed = self[:emailed_booking_ids]? ? Array(Int64).from_json(self[:emailed_booking_ids].to_json) : [] of Int64
    # remove previously emailed bookings that are no longer pending release
    previously_emailed -= previously_emailed - bookings.map(&.id)
    # add previously emailed bookings that are still pending release
    emailed_booking_ids += previously_emailed

    bookings.each do |booking|
      next if previously_released.includes? booking.id
      next if previously_emailed.includes? booking.id

      # convert minutes (time_after) to seconds for comparison with unix timestamps (booking_start)
      if enabled? &&
         (booking.booking_start - Time.utc.to_unix < @auto_release.time_before * 60) &&
         (Time.utc.to_unix - booking.booking_start < @auto_release.time_after * 60)
        logger.debug { "sending release email to #{booking.user_email} for booking #{booking.id} as it is withing the time_before window" }

        timezone = booking.timezone.presence || @timezone.name
        location = Time::Location.load(timezone)

        starting = Time.unix(booking.booking_start).in(location)
        ending = Time.unix(booking.booking_end).in(location)

        args = {
          booking_id:    booking.id,
          booking_start: booking.booking_start,
          booking_end:   booking.booking_end,

          start_time:     starting.to_s(@time_format),
          start_date:     starting.to_s(@date_format),
          start_datetime: starting.to_s(@date_time_format),
          end_time:       ending.to_s(@time_format),
          end_date:       ending.to_s(@date_format),
          end_datetime:   ending.to_s(@date_time_format),

          asset_id:   booking.asset_id,
          user_id:    booking.user_id,
          user_email: booking.user_email,
          user_name:  booking.user_name,
          reason:     booking.title,

          approver_name:  booking.approver_name,
          approver_email: booking.approver_email,

          booked_by_name:  booking.booked_by_name,
          booked_by_email: booking.booked_by_email,
        }

        begin
          mailer.send_template(
            to: booking.user_email,
            template: {@email_template, "auto_release"},
            args: args)
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

  # start_time: Start time of work hours. e.g. `7.5` being 7:30AM
  # end_time: End time of work hours. e.g. `18.5` being 6:30PM
  # location: Name of the location the work is being performed at
  struct WorktimeBlock
    include JSON::Serializable

    property start_time : Float64
    property end_time : Float64
    property location : String = ""
  end

  # day_of_week: Index of the day of the week. `0` being Sunday
  struct WorktimePreference
    include JSON::Serializable

    property day_of_week : Int32
    property blocks : Array(WorktimeBlock) = [] of WorktimeBlock
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

  struct Zone
    include JSON::Serializable

    property id : String

    property name : String
    property description : String
    property tags : Set(String)
    property location : String?
    property display_name : String?
    property timezone : String?

    property parent_id : String?

    @[JSON::Field(ignore: true)]
    @time_location : Time::Location?

    def time_location? : Time::Location?
      if tz = timezone.presence
        @time_location ||= Time::Location.load(tz)
      end
    end

    def time_location! : Time::Location
      time_location?.not_nil!
    end
  end
end
