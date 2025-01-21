require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"

class Place::AtCapacityMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS At Capacity Mailer"
  generic_name :AtCapacityMailer
  description %()

  default_settings({
    timezone:              "Australia/Sydney",
    date_time_format:      "%c",
    time_format:           "%l:%M%p",
    date_format:           "%A, %-d %B",
    booking_type:          "desk",       # desk, locker, parking, etc
    zones:                 [] of String, # The zones to check for bookings
    notify_email:          ["concierge@place.com"],
    email_schedule:        "*/5 * * * *", # the frequency to check for bookings
    time_window_hours:     1,             # the number of hours to check for bookings
    debounce_time_minutes: 60,            # the time to wait before sending another email
    email_template:        "at_capacity",
    unique_templates:      false, # this appends the booking type to the template name
  })

  accessor staff_api : StaffAPI_1

  # accessor calendar : Calendar_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    on_update
  end

  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

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

  def on_update
    time_zone = setting?(String, :calendar_time_zone).presence || "Australia/Sydney"
    @time_zone = Time::Location.load(time_zone)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @booking_type = setting?(String, :booking_type).presence || "desk"
    @zones = setting?(Array(String), :zones) || [] of String

    @notify_email = setting?(Array(String), :notify_email) || [] of String
    @email_schedule = setting?(String, :email_schedule).presence || "*/5 * * * *"
    @time_window_hours = setting?(Int32, :time_window_hours) || 1
    @debounce_time_minutes = setting?(Int32, :debounce_time_minutes) || 60

    @unique_templates = setting?(Bool, :unique_templates) || false
    @template_suffix = @unique_templates ? "_#{@booking_type}" : ""
    @template_fields_suffix = @unique_templates ? " (#{@booking_type})" : ""

    schedule.clear

    # find assets
    # schedule.every(5.minutes) { get_asset_ids }

    if emails = @email_schedule
      schedule.cron(emails, @time_zone) { check_capacity }
    end
  end

  @[Security(Level::Support)]
  def check_capacity
    # asset_ids = self[:assets_ids]? ? Hash(String, Array(String)).from_json(self[:assets_ids].to_json) : {} of String => Array(String)

    asset_ids = get_asset_ids
    booked_asset_ids = get_booked_asset_ids

    @zones.each do |zone_id|
      next if asset_ids[zone_id].empty?

      if (asset_ids[zone_id] - [booked_asset_ids]).empty?
        logger.debug { "zone #{zone_id} is at capacity" }
        send_email(zone_id)
      end
    end
  end

  def get_asset_ids : Array(String)
    assets_ids = {} of String => Array(String)

    @zones.each do |zone_id|
      assets_ids[zone_id] = get_assets_from_metadata(@booking_type, zone_id).map { |asset| asset.id }
    end

    # MAYBE: get assets from DB (staff-api) if it's not an asset type stored in metadata

    self[:assets_ids] = assets_ids.unique
  rescue error
    logger.warn(exception: error) { "unable to get #{type} assets from zone #{zone_id} metadata" }
    self[:assets_ids][zone_id] = [] of String
  end

  def get_assets_from_metadata(type : String, zone_id : String) : Array(Asset?)
    metadata_field = case type
                     when "desk"
                       "desks"
                     when "parking"
                       "parking-spaces"
                     when "locker"
                       "lockers"
                     end

    if metadata_field
      metadata = Metadata.from_json staff_api.metadata(zone_id, metadata_field).get[metadata_field].to_json
      if "lockers"
        metadata.details.flat_map { |locker_bank| locker_bank.as_h["lockers"].as_a.map { |locker| Asset.from_json locker.to_json } }
      else
        metadata.details.as_a.map { |asset| Asset.from_json asset.to_json }
      end
    end
  rescue error
    logger.warn(exception: error) { "unable to get #{type} assets from zone #{zone_id} metadata" }
    nil
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

    args = {
      zone_id:      zone_id,
      booking_type: @booking_type,
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
          {name: "zone_id", description: "Identifier of the zone that is at capacity"},
          {name: "booking_type", description: "Type of booking that is at capacity"},
        ]
      ),
    ]
  end

  struct Metadata
    include JSON::Serializable

    property name : String
    property description : String = ""
    property details : JSON::Any
    property parent_id : String
    property schema_id : String? = nil
    property editors : Set(String) = Set(String).new
    property modified_by_id : String? = nil
  end

  struct Asset
    include JSON::Serializable

    property id : String
    property name : String
  end
end
