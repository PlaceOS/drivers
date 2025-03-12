require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"
require "./bookings/asset_name_resolver"

class Place::AtCapacityMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates
  include Place::AssetNameResolver

  descriptive_name "PlaceOS At Capacity Mailer"
  generic_name :AtCapacityMailer
  description %(sends a notification when the specified type is at capacity)

  default_settings({
    timezone:              "Australia/Sydney",
    booking_type:          "desk",       # desk, locker, parking, etc
    zones:                 [] of String, # The zones to check for bookings
    notify_email:          ["concierge@place.com"],
    email_schedule:        "*/5 * * * *", # the frequency to check for bookings
    time_window_hours:     1,             # the number of hours to check for bookings
    debounce_time_minutes: 60,            # the time to wait before sending another email
    email_template:        "at_capacity",
    unique_templates:      false,    # this appends the booking type to the template name
    asset_cache_timeout:   3600_i64, # 1 hour
  })

  accessor staff_api : StaffAPI_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  # used by AssetNameResolver and LockerMetadataParser
  accessor locations : LocationServices_1
  getter building_id : String do
    locations.building_id.get.as_s
  end
  getter levels : Array(String) do
    staff_api.systems_in_building(building_id).get.as_h.keys
  end

  def on_load
    on_update
  end

  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")

  @booking_type : String = "desk"
  @zones : Array(String) = [] of String

  @notify_email : Array(String) = [] of String
  @email_schedule : String = "*/5 * * * *"
  @time_window_hours : Int32 = 1
  @debounce_time_minutes : Int32 = 60
  @last_email_sent : Hash(String, Time) = {} of String => Time

  @email_template : String = "at_capacity"
  @unique_templates : Bool = false
  @template_suffix : String = ""
  @template_fields_suffix : String = ""

  @zone_cache : Hash(String, Zone) = {} of String => Zone

  def on_update
    @building_id = nil
    @levels = nil

    time_zone = setting?(String, :calendar_time_zone).presence || "Australia/Sydney"
    @time_zone = Time::Location.load(time_zone)

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @zones = setting?(Array(String), :zones) || [] of String

    @notify_email = setting?(Array(String), :notify_email) || [] of String
    @email_schedule = setting?(String, :email_schedule).presence || "*/5 * * * *"
    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @debounce_time_minutes = setting?(Int32, :debounce_time_minutes) || 60

    @email_template = setting?(String, :email_template) || "at_capacity"
    @unique_templates = setting?(Bool, :unique_templates) || false
    @template_suffix = @unique_templates ? "_#{@booking_type}" : ""
    @template_fields_suffix = @unique_templates ? " (#{@booking_type})" : ""

    @asset_cache_timeout = setting?(Int64, :asset_cache_timeout) || 3600_i64
    clear_asset_cache

    schedule.clear

    # find assets
    schedule.every(60.minutes) { get_asset_ids }

    if emails = @email_schedule
      schedule.cron(emails, @time_zone) { check_capacity }
    end
  end

  @[Security(Level::Support)]
  def check_capacity
    asset_ids = self[:assets_ids]? ? Hash(String, Array(String)).from_json(self[:assets_ids].to_json) : get_asset_ids

    booked_asset_ids = get_booked_asset_ids

    @zones.each do |zone_id|
      next unless (zone_asset_ids = asset_ids[zone_id]?) && !zone_asset_ids.empty?

      if (zone_asset_ids - booked_asset_ids).empty?
        logger.debug { "zone #{zone_id} is at capacity" }
        send_email(zone_id)
      end
    end
  end

  def get_asset_ids : Hash(String, Array(String))
    assets_ids = {} of String => Array(String)

    @zones.each do |zone_id|
      assets_ids[zone_id] = lookup_assets(zone_id, @booking_type).map { |asset| asset.id }.uniq!
    end

    self[:assets_ids] = assets_ids
  end

  def get_booked_asset_ids : Array(String)
    asset_ids = Array(String).from_json staff_api.booked(
      type: @booking_type,
      period_start: Time.utc.to_unix,
      period_end: (Time.utc + @time_window_hours.hours).to_unix,
      zones: @zones,
    ).get.to_json

    logger.debug { "found #{asset_ids.size} booked assets" }

    self[:booked_assets] = asset_ids
  rescue error
    logger.warn(exception: error) { "unable to obtain list of booked assets" }
    self[:booked_assets] = [] of String
  end

  @[Security(Level::Support)]
  def send_email(zone_id : String)
    if (last = @last_email_sent[zone_id]?) && Time.utc - last < @debounce_time_minutes.minutes
      logger.debug { "skipping email for #{zone_id} due to debounce timer" }
      return
    end

    zone = fetch_zone(zone_id)
    args = {
      booking_type:      @booking_type,
      zone_id:           zone_id,
      zone_name:         zone.name,
      zone_description:  zone.description,
      zone_location:     zone.location,
      zone_display_name: zone.display_name,
      zone_timezone:     zone.timezone,
    }

    begin
      mailer.send_template(
        to: @notify_email,
        template: {"at_capacity", "#{@email_template}#{@template_suffix}"},
        args: args)
      @last_email_sent[zone_id] = Time.utc
    rescue error
      logger.warn(exception: error) { "failed to send at capacity email for zone #{zone_id}" }
    end
  end

  def template_fields : Array(TemplateFields)
    [
      TemplateFields.new(
        trigger: {@email_template, "at_capacity#{@template_suffix}"},
        name: "At capacity#{@template_fields_suffix}",
        description: "Notification when the assets of a zone is at capacity",
        fields: [
          {name: "booking_type", description: "Type of booking that is at capacity"},
          {name: "zone_id", description: "Identifier of the zone that is at capacity"},
          {name: "zone_name", description: "Name of the zone that is at capacity"},
          {name: "zone_description", description: "Description of the zone that is at capacity"},
          {name: "zone_location", description: "Location of the zone that is at capacity"},
          {name: "zone_display_name", description: "Display name of the zone that is at capacity"},
          {name: "zone_timezone", description: "Timezone of the zone that is at capacity"},
        ]
      ),
    ]
  end

  def fetch_zone(zone_id : String) : Zone
    @zone_cache[zone_id] ||= Zone.from_json staff_api.zone(zone_id).get.to_json
  rescue error
    logger.warn(exception: error) { "unable to find zone #{zone_id}" }
    Zone.new(id: zone_id)
  end

  struct Zone
    include JSON::Serializable

    property id : String

    property name : String = ""
    property description : String = ""
    property tags : Set(String) = Set(String).new
    property location : String?
    property display_name : String?
    property timezone : String?

    property parent_id : String?

    def initialize(@id : String)
    end

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
