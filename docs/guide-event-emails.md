# How to email people when an event occurs

There are three aspects to this

1. Sending an email in real-time as an event occurs
2. Batching events (either periodically or via a [CRON](https://crontab.guru/))
3. Managing state (state machine management)

For example...
- Send an email straight away if the event is today, otherwise, send them at 7 am every morning and mark the emails as sent.
- Poll every 15min to send any emails that were missed due to an outage (by checking state)


## Example logic driver

```crystal
require "placeos-driver/interface/mailer"

class DeskBookingNotification < PlaceOS::Driver
  descriptive_name "Desk Booking Approval"
  generic_name :BookingApproval

  default_settings({
    # https://www.iana.org/time-zones
    timezone:         "Australia/Sydney",
    # https://crystal-lang.org/api/latest/Time/Format.html
    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",
    booking_type:     "desk",
    buildings: ["zone-123", "zone-456"],
  })

  # this ensures these variables are not nilable
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"
  @booking_type : String = "desk"
  @buildings : Array(String) = [] of String

  def on_update
    # Update the instance variables based on the settings
    time_zone = setting?(String, :calendar_time_zone).presence || "Australia/Sydney"
    @time_zone = Time::Location.load(time_zone)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @booking_type = setting?(String, :booking_type).presence || "desk"
    @buildings = setting?(Array(String), :buildings) || [] of String

    # configure any schedules here
    # https://github.com/spider-gazelle/tasker
    schedule.clear
    schedule.every(5.minutes) { poll_bookings }
    schedule.cron("30 7 * * *", @time_zone) { poll_bookings }
  end

  def on_load
    # Some form of asset booking has occurred (such as a desk booking)
    monitor("staff/booking/changed") { |_subscription, payload| check_booking(payload) }

    on_update
  end

  # Get a reference to a module that can be used to send emails
  def mailer
    system.implementing(Interface::Mailer)
  end

  # Access another module in the system
  accessor staff_api : StaffAPI_1

  protected def check_booking(payload : String)
    logger.debug { "received booking event payload: #{payload}" }
    booking_details = Booking.from_json payload
    process_booking(booking_details)
  end

  # ensure we don't have two fibers processing this at once
  # (technically the driver is thread-safe, but it is concurrent)
  @check_bookings_mutex = Mutex.new

  @[Security(Level::Support)]
  def poll_bookings(months_from_now : Int32 = 2)
    # Clean up old debounce data
    expired = 5.minutes.ago.to_unix
    @debounce.reject! { |_, (_event, entered)| expired > entered }

    now = Time.utc.to_unix
    later = months_from_now.months.from_now.to_unix

    @check_bookings_mutex.synchronize do
      @buildings.each do |building_zone|
        # bookings that haven't been approved
        bookings = staff_api.query_bookings(
          type: @booking_type,
          period_start: now,
          period_end: later,
          zones: [building_zone],
          approved: false,
          rejected: false,
          created_before: 2.minutes.ago.to_unix
        ).get.as_a

        # bookings that have been approved
        bookings = bookings + staff_api.query_bookings(
          type: @booking_type,
          period_start: now,
          period_end: later,
          zones: [building_zone],
          approved: true,
          rejected: false,
          created_before: 2.minutes.ago.to_unix
        ).get.as_a

        # Convert to nice objects
        bookings = Array(Booking).from_json(bookings.to_json)

        logger.debug { "checking #{bookings.size} requested bookings in #{building_zone}" }
        bookings.each { |booking_details| process_booking(booking_details) }
      end
    end
  end

  # Booking id => event action, timestamp
  @debounce = {} of Int64 => {String?, Int64}
  @bookings_checked = 0_u64

  # See the booking model at the end of this document
  protected def process_booking(booking_details : Booking)
    # Ignore when a bookings state is updated
    return if {"process_state", "metadata_changed"}.includes?(booking_details.action)

    # Ignore the same event in a short period of time
    previous = @debounce[booking_details.id]?
    return if previous && previous[0] == booking_details.action
    @debounce[booking_details.id] = {booking_details.action, Time.utc.to_unix}

    # timezone, if different from the default
    timezone = booking_details.timezone.presence || @time_zone.name
    location = Time::Location.load(timezone)

    # https://crystal-lang.org/api/0.35.1/Time/Format.html
    # date and time (Tue Apr 5 10:26:19 2016)
    starting = Time.unix(booking_details.booking_start).in(location)
    ending = Time.unix(booking_details.booking_end).in(location)

    # Ignore changes to meetings that have already ended
    return if Time.utc > ending

    building_zone, building_name = get_building_details(booking_details.zones)

    # These are the available keys for use in the templates
    args = {
      booking_id:     booking_details.id,
      start_time:     starting.to_s(@time_format),
      start_date:     starting.to_s(@date_format),
      start_datetime: starting.to_s(@date_time_format),
      end_time:       ending.to_s(@time_format),
      end_date:       ending.to_s(@date_format),
      end_datetime:   ending.to_s(@date_time_format),
      starting_unix:  booking_details.booking_start,

      desk_id:    booking_details.asset_id,
      user_id:    booking_details.user_id,
      user_email: booking_details.user_email,
      user_name:  booking_details.user_name,
      reason:     booking_details.title,

      level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
      building_zone: building_zone,
      building_name: building_name,
      support_email: support_email,

      approver_name:  booking_details.approver_name,
      approver_email: booking_details.approver_email,

      booked_by_name:  booking_details.booked_by_name,
      booked_by_email: booking_details.booked_by_email,
    }

    case booking_details.action
    when "create", "changed"
      # check if email already sent and we can ignore this one
      next if booking_details.process_state == "notification_sent"

      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", "booking_notification"},
        args: args
      )

      # update the booking state (if there are multiple states a booking can be in)
      staff_api.booking_state(booking_details.id, "notification_sent").get
    when "approved"
      # if there is an approval process
      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", "booking_approved"},
        args: args
      )

      staff_api.booking_state(booking_details.id, "approval_sent").get
    when "rejected", "checked_in"
      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", booking_details.action},
        args: args
      )
    when "cancelled"
      # maybe someone else cancelled your booking and you have a custom template for that
      third_party = booking_details.approver_email && booking_details.approver_email != booking_details.user_email.downcase

      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", third_party ? "cancelled_by" : "cancelled"},
        args: args
      )

      # maybe you want to notifty the persons manager about this
      if manager_email = get_manager(user_email).try(&.at(0))
        mailer.send_template(
          to: manager_email,
          template: {"bookings", "manager_notify_cancelled"},
          args: args
        )
      end
    end

    # nice to see some status in backoffice
    @bookings_checked += 1
    self[:bookings_checked] = @bookings_checked
  end

  # id => tags, name
  @zone_cache = {} of String => Tuple(Array(String), String)

  def get_building_details(zones : Array(String))
    zones.each do |zone_id|
      zone_info = @zone_cache[zone_id]? || get_zone(zone_id)
      next unless zone_info
      next unless zone_info[0].includes?("building")

      return {zone_id, zone_info[1]}
    end

    nil
  end

  def get_zone(zone_id : String)
    zone = staff_api.zone(zone_id).get
    tags = zone["tags"].as_a.map(&.as_s)
    name = zone["name"].as_s
    tuple = {tags, name}
    @zone_cache[zone_id] = tuple
    tuple
  rescue error
    logger.warn(exception: error) { "error obtaining zone details for #{zone_id}" }
    nil
  end

  @[Security(Level::Support)]
  def get_manager(staff_email : String)
    # The Calendar driver is hooked up to MS Graph API for example
    # could have used an accessor here like `staff_api`, that's optional
    manager = system[:Calendar_1].get_user_manager(staff_email).get
    {(manager["email"]? || manager["username"]).as_s, manager["name"].as_s}
  rescue error
    logger.warn(exception: error) { "failed to obtain manager of #{staff_email}" }
    {nil, nil}
  end
end

```


### List of Staff API events

These are events that can be monitored `monitor("event/path") { |sub, payload| }`

* booking (desk, car space etc) - `"staff/booking/changed"`
  * [boooking event model](https://github.com/place-labs/staff-api/blob/master/src/controllers/bookings.cr#L80)
  * `action` types: create, cancelled, changed, metadata_changed, approved, rejected, checked_in, process_state
* events (calendar events) - `"staff/event/changed"`
  * [event event model](https://github.com/place-labs/staff-api/blob/master/src/controllers/events.cr#L130)
  * `action` types: create, update, cancelled
* a guest has been invited onsite - `"staff/guest/attending"`
  * [guest attending model](https://github.com/place-labs/staff-api/blob/master/src/controllers/events.cr#L195)
  * `action` types: meeting_created, meeting_update
* a guest has arrived onsite - `"staff/guest/checkin"`
  * [guest checkin model](https://github.com/place-labs/staff-api/blob/master/src/controllers/events.cr#L723)


### Booking Model

This model covers events and API responses

```crystal

class Booking
  include JSON::Serializable

  # This is to support events
  property action : String?

  property id : Int64
  property booking_type : String
  property booking_start : Int64
  property booking_end : Int64
  property timezone : String?

  # events use resource_id instead of asset_id
  property asset_id : String?
  property resource_id : String?

  def asset_id : String
    (@asset_id || @resource_id).not_nil!
  end

  property user_id : String
  property user_email : String
  property user_name : String

  property zones : Array(String)

  property checked_in : Bool?
  property rejected : Bool?
  property approved : Bool?
  property process_state : String?
  property last_changed : Int64?

  property approver_name : String?
  property approver_email : String?

  property booked_by_name : String
  property booked_by_email : String

  property checked_in : Bool?
  property title : String?
  property description : String?

  property extension_data : Hash(String, JSON::Any)

  def in_progress?
    now = Time.utc.to_unix
    now >= @booking_start && now < @booking_end
  end

  def changed
    Time.unix(last_changed.not_nil!)
  end
end

```

### Email templates

Email templates are applied to the mailer driver and then other drivers can use them to send emails.

see the [mailer interface](https://github.com/PlaceOS/driver/blob/master/src/placeos-driver/interface/mailer.cr#L27) for details on available params

The templates are settings, structured like:

```yaml

email_templates:
  category:
    template_name:
      subject: the email subject line with %{variables}
      text: the text version of an email
      html: <p>the HTML version of the email</p>

```

typically only the `html` version of an email is required

```yaml

email_templates:
  bookings:
    rejected:
      subject: 'Desk Booking: Manager rejection'
      html: >
        <html><body>

        This is a short note to advise that your desk booking request for
        %{start_date} at %{building_name} has been rejected.

        <br /><br />

        Please reach out to your manager <a
        href="mailto:%{approver_email}">%{approver_name}</a> if you would like
        to follow up.

        <br /><br />

        Your request has been removed from the system and we look forward to
        welcoming you to our workplace in the future.

        <br /><br />

        Kind Regards

        <br />

        The Corporate Real Estate Team

        </body></html>
    cancelled:
      subject: Desk booking cancellation confirmation
      text: >
        Thank you for taking the time to cancel your booking which we appreciate
        so we can continue to operate with efficiency and excellence.


        Your desk booking on %{start_date} at %{building_name} has been
        cancelled.


        Please reach out to your workplace support team should you have any
        other queries, otherwise we look forward to seeing you soon
      html: >
        <html><body>

        Thank you for taking the time to cancel your booking which we appreciate
        so we can continue to operate with efficiency and excellence.

        <br /><br />

        Your desk booking on %{start_date} at %{building_name} has been
        cancelled.

        <br /><br />

        Please reach out to your <a
        href="mailto:%{support_email}?subject=%{building_name} workplace
        question">workplace support team</a> should you have any other queries,
        otherwise, we look forward to seeing you soon

        </body></html>

```
