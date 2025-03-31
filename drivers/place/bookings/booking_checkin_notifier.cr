require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "../booking_model"

class Place::BookingCheckinNotifier < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "Booking checkin notifier"
  generic_name :BookingCheckinNotifier
  description %(notifies information by email when bookings are checked in)

  default_settings({
    notify_address:            "mailing_list@org.com",
    date_time_format:          "%c",
    time_format:               "%l:%M%p",
    date_format:               "%A, %-d %B",
    determine_host_name_using: "calendar-driver",
    booking_type:              "parking",
    _zone_override:            "booking zone id",
  })

  accessor calendar : Calendar_1
  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    monitor("staff/booking/changed") { |_subscription, payload| parse_booking(payload) }
    on_update
  end

  # See: https://crystal-lang.org/api/latest/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"
  @zone_override : String? = nil
  @booking_type : String = "parking"
  @bookings_checked : UInt64 = 0_u64
  @notify_address : String = ""

  def on_update
    @building_id = nil
    @building = nil
    @building_name = nil
    @zone_override = setting?(String, :zone_override)

    @notify_address = setting(String, :notify_address)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @booking_type = setting?(String, :booking_type).presence || "parking"
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  getter building : JSON::Any do
    staff_api.zone(building_id).get
  end

  getter building_name : String do
    building["name"].as_s
  end

  # system or building timezone
  protected getter timezone : Time::Location do
    tz = config.control_system.try(&.timezone) || building["timezone"].as_s
    Time::Location.load(tz)
  end

  protected def parse_booking(payload)
    booking_details = Booking.from_json payload

    # Only process booking types of interest
    return unless booking_details.booking_type == @booking_type

    # We only care for checked in
    return unless booking_details.action == "checked_in"

    # in a particular zone
    return unless booking_details.zones.includes?(@zone_override || building_id)

    logger.debug { "received checked_in event payload:\n#{payload}" }
    notify_check_in booking_details
  end

  protected def notify_check_in(booking_details)
    # https://crystal-lang.org/api/0.35.1/Time/Format.html
    # date and time (Tue Apr 5 10:26:19 2016)
    location = timezone
    starting = Time.unix(booking_details.booking_start).in(location)
    ending = Time.unix(booking_details.booking_end).in(location)

    # Ignore changes to meetings that have already ended
    return if Time.utc > ending

    args = {
      booking_id:     booking_details.id,
      start_time:     starting.to_s(@time_format),
      start_date:     starting.to_s(@date_format),
      start_datetime: starting.to_s(@date_time_format),
      end_time:       ending.to_s(@time_format),
      end_date:       ending.to_s(@date_format),
      end_datetime:   ending.to_s(@date_time_format),
      starting_unix:  booking_details.booking_start,

      asset_id:   booking_details.asset_id,
      user_id:    booking_details.user_id,
      user_email: booking_details.user_email,
      user_name:  booking_details.user_name,
      reason:     booking_details.title,

      building_zone: building_id,
      building_name: building_name,

      approver_name:  booking_details.approver_name,
      approver_email: booking_details.approver_email,

      booked_by_name:  booking_details.booked_by_name,
      booked_by_email: booking_details.booked_by_email,
    }

    mailer.send_template(
      to: @notify_address,
      template: {"bookings", "check_in_notifier"},
      args: args
    )

    @bookings_checked += 1
    self[:bookings_checked] = @bookings_checked
  end

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(timezone)
    common_fields = [
      {name: "booking_id", description: "Unique identifier for the booking"},
      {name: "start_time", description: "Booking start time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "start_date", description: "Booking start date (e.g., #{time_now.to_s(@date_format)})"},
      {name: "start_datetime", description: "Booking start date and time (e.g., #{time_now.to_s(@date_time_format)})"},
      {name: "end_time", description: "Booking end time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "end_date", description: "Booking end date (e.g., #{time_now.to_s(@date_format)})"},
      {name: "end_datetime", description: "Booking end date and time (e.g., #{time_now.to_s(@date_time_format)})"},
      {name: "starting_unix", description: "Booking start time as Unix timestamp"},
      {name: "asset_id", description: "Identifier of the booked asset (e.g., desk)"},
      {name: "user_id", description: "Identifier of the person the booking is for"},
      {name: "user_email", description: "Email of the person the booking is for"},
      {name: "user_name", description: "Name of the person the booking is for"},
      {name: "reason", description: "Purpose or title of the booking"},
      {name: "building_zone", description: "Zone identifier for the building"},
      {name: "building_name", description: "Name of the building"},
      {name: "approver_name", description: "Name of the person who approved/rejected the booking"},
      {name: "approver_email", description: "Email of the person who approved/rejected the booking"},
      {name: "booked_by_name", description: "Name of the person who made the booking"},
      {name: "booked_by_email", description: "Email of the person who made the booking"},
    ]

    [
      TemplateFields.new(
        trigger: {"bookings", "check_in_notifier"},
        name: "Booking check in notifier",
        description: "Notification to a mailing group when a booking is checked in",
        fields: common_fields
      ),
    ]
  end
end
