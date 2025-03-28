require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"
require "./booking_model"
require "./bookings/asset_name_resolver"

class Place::AutoRelease < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates
  include Place::AssetNameResolver

  descriptive_name "PlaceOS Auto Release"
  generic_name :AutoRelease
  description %(emails visitors to confirm automatic release of their booking when they have indicated they are not on-site and releases the booking if they do not confirm)

  default_settings({
    date_time_format:  "%c",
    time_format:       "%l:%M%p",
    date_format:       "%A, %-d %B",
    email_schedule:    "*/5 * * * *",
    email_template:    "auto_release",
    unique_templates:  false,
    time_window_hours: 4,              # The number of hours to check for bookings pending release
    release_locations: ["wfh", "aol"], # Locations to release bookings for
    # available locations:
    # - wfh: Work From Home
    # - aol: Away on Leave
    # - wfo: Work From Office
    skip_created_after_start: true,                     # Skip bookings created after the start time
    skip_same_day:            false,                    # Skip bookings created on the same day as the booking
    default_work_preferences: [] of WorktimePreference, # Default work preferences for users
    release_outside_hours:    false,                    # Release bookings outside of work hours
    all_day_start:            8.0,                      # Start time used for all day bookings
    asset_cache_timeout:      3600_i64,                 # 1 hour
  })

  accessor staff_api : StaffAPI_1

  getter building_zone : Zone { get_building_zone?.not_nil! }

  # used by AssetNameResolver and LockerMetadataParser
  getter building_id : String { building_zone.id }
  getter levels : Array(String) do
    staff_api.systems_in_building(building_id).get.as_h.keys
  end

  protected getter timezone : Time::Location do
    tz = config.control_system.try(&.timezone) || building_zone.timezone.presence || "UTC"
    Time::Location.load(tz)
  end

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  @auto_release_emails_sent : UInt64 = 0_u64
  @auto_release_email_errors : UInt64 = 0_u64

  @email_template : String = "auto_release"
  @unique_templates : Bool = false
  @email_schedule : String? = nil

  @time_window_hours : Int32 = 1
  @release_locations : Array(String) = ["wfh", "aol"]
  @auto_release : AutoReleaseConfig = AutoReleaseConfig.new
  @skip_created_after_start : Bool = true
  @skip_same_day : Bool = true
  @default_work_preferences : Array(WorktimePreference) = [] of WorktimePreference
  @release_outside_hours : Bool = false
  @all_day_start : Float64 = 8.0

  def on_update
    @building_zone = nil
    @building_id = nil
    @levels = nil
    @timezone = nil

    @email_schedule = setting?(String, :email_schedule).presence
    @email_template = setting?(String, :email_template) || "auto_release"
    @unique_templates = setting?(Bool, :unique_templates) || false

    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @release_locations = setting?(Array(String), :release_locations) || ["wfh", "aol"]
    @auto_release = setting?(AutoReleaseConfig, :auto_release) || AutoReleaseConfig.new
    @skip_created_after_start = setting?(Bool, :skip_created_after_start) || true
    @skip_same_day = setting?(Bool, :skip_same_day) || false
    @default_work_preferences = setting?(Array(WorktimePreference), :default_work_preferences) || [] of WorktimePreference
    @release_outside_hours = setting?(Bool, :release_outside_hours) || false
    @all_day_start = setting?(Float64, :all_day_start) || 8.0

    @asset_cache_timeout = setting?(Int64, :asset_cache_timeout) || 3600_i64
    clear_asset_cache

    schedule.clear

    # find bookins pending release
    schedule.every(5.minutes) { pending_release }

    # release bookings
    schedule.every(1.minute) { release_bookings }

    if emails = @email_schedule
      schedule.cron(emails, timezone) { send_release_emails }
    end
  end

  # Finds the building zone for the current location services object
  def get_building_zone? : Zone?
    zones = Array(Zone).from_json staff_api.zones(tags: "building").get.to_json
    zone_ids = zones.map(&.id)
    zone_id = (zone_ids & system.zones).first
    zones.find { |zone| zone.id == zone_id }
  rescue error
    logger.error(exception: error) { "unable to determine building zone" }
    nil
  end

  @[Security(Level::Support)]
  def enabled? : Bool
    if !@auto_release.resources.empty? &&
       !building_zone.time_location?.nil?
      true
    else
      logger.notice { "auto release is not enabled on zone #{building_zone.id}" }
      logger.debug { "auto release is not enabled on zone #{building_zone.id} due to auto_release.resources being empty" } if @auto_release.resources.empty?
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
    logger.error(exception: error) { "unable to obtain list of bookings" }
    self[:pending_bookings] = [] of Booking
  end

  @[Security(Level::Support)]
  def get_user_preferences?(user_id : String)
    user = staff_api.user(user_id).get

    work_preferences = Array(WorktimePreference).from_json user.as_h["work_preferences"].to_json
    work_preferences = @default_work_preferences if work_preferences.empty?

    work_overrides = Hash(String, WorktimePreference).from_json user.as_h["work_overrides"].to_json

    {work_preferences: work_preferences, work_overrides: work_overrides}
  rescue
    logger.warn { "unable to obtain work location for user #{user_id}" }
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
      next if @skip_created_after_start && (created_at = booking.created) && created_at >= booking.booking_start
      next if @skip_same_day && (created_at = booking.created) &&
              Time.unix(created_at).in(building_zone.time_location!).day == Time.unix(booking.booking_start).in(building_zone.time_location!).day

      if preferences = get_user_preferences?(booking.user_id)
        # get the booking start time in the building timezone
        booking_start = Time.unix(booking.booking_start).in building_zone.time_location!

        day_of_week = booking_start.day_of_week.value
        day_of_week = 0 if day_of_week == 7 # Crystal uses 7 for Sunday, but we use 0 (all other days match up)

        # convert unix timestamp to float hours/minutes
        # e.g. 7:30AM = 7.5
        event_time = booking_start.hour + (booking_start.minute / 60.0)

        # use all_day_start for all day bookings
        event_time = @all_day_start if booking.all_day

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
        elsif @release_outside_hours
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

      # convert hours (all_day_start) to seconds
      booking_start = booking.all_day ? (@all_day_start * 60 * 60).to_i : booking.booking_start
      # convert minutes (time_after) to seconds for comparison with unix timestamps (booking_start)
      if Time.utc.to_unix - booking_start > @auto_release.time_after(booking.type) * 60
        # skip if there's been changes to the cached bookings checked_in status or booking_start time
        next if skip_release?(booking)

        logger.debug { "rejecting booking #{booking.id} as it is within the time_after window" }
        staff_api.reject(booking.id, "auto_release", booking.instance).get
        released_booking_ids << booking.id
      end
    end

    logger.debug { "released #{released_booking_ids.size} bookings" }

    self[:released_booking_ids] = released_booking_ids
  rescue error
    logger.error(exception: error) { "unable to release bookings" }
    self[:released_booking_ids] = [] of Int64
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
         (booking.booking_start - Time.utc.to_unix < @auto_release.time_before(booking.type) * 60) &&
         (Time.utc.to_unix - booking.booking_start < @auto_release.time_after(booking.type) * 60)
        logger.debug { "sending release email to #{booking.user_email} for booking #{booking.id} as it is withing the time_before window" }

        location = Time::Location.load(booking.timezone.presence || timezone.name)
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
          asset_name: lookup_asset(asset_id: booking.asset_id, type: booking.booking_type, zones: booking.zones),
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
            template: {@email_template, "auto_release#{template_suffix(booking.booking_type)}"},
            args: args)
          emailed_booking_ids << booking.id
        rescue error
          logger.warn(exception: error) { "failed to send release email to #{booking.user_email}" }
        end
      end
    end
    self[:emailed_booking_ids] = emailed_booking_ids
  end

  def template_fields : Array(TemplateFields)
    if @unique_templates && !@auto_release.resources.empty?
      @auto_release.resources.map { |type| unique_template_fields(type) }
    else
      [unique_template_fields]
    end
  end

  private def unique_template_fields(booking_type : String = "") : TemplateFields
    time_now = Time.utc.in(timezone)

    TemplateFields.new(
      trigger: {@email_template, "auto_release#{template_suffix(booking_type)}"},
      name: "Auto release booking#{template_fields_suffix(booking_type)}",
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
        {name: "asset_name", description: "Name of the booked resource"},
        {name: "user_id", description: "Identifier of the person who has the booking"},
        {name: "user_email", description: "Email address of the person who has the booking"},
        {name: "user_name", description: "Full name of the person who has the booking"},
        {name: "reason", description: "Title or purpose of the booking"},
        {name: "approver_name", description: "Name of the person who approved the booking"},
        {name: "approver_email", description: "Email of the person who approved the booking"},
        {name: "booked_by_name", description: "Name of the person who made the booking"},
        {name: "booked_by_email", description: "Email of the person who made the booking"},
      ]
    )
  end

  private def template_suffix(booking_type : String) : String
    @unique_templates && !@auto_release.resources.empty? ? "_#{booking_type}" : ""
  end

  private def template_fields_suffix(booking_type : String) : String
    @unique_templates && !@auto_release.resources.empty? ? " (#{booking_type})" : ""
  end

  struct AutoReleaseConfig
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter time_before : Int64 = 0 # minutes
    getter time_after : Int64 = 0  # minutes
    getter resources : Array(String) = [] of String

    # getter all_day_start : Float64 = 8.0 # hours

    def time_before(resource : String) : Int64
      if resource_time_before = json_unmapped["#{resource}_time_before"]?
        resource_time_before.as_i64
      else
        time_before
      end
    end

    def time_after(resource : String) : Int64
      if resource_time_after = json_unmapped["#{resource}_time_after"]?
        resource_time_after.as_i64
      else
        time_after
      end
    end
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
