require "placeos-driver"
require "placeos-driver/interface/chat_functions"
require "place_calendar"

class Place::Schedule < PlaceOS::Driver
  include Interface::ChatFunctions

  descriptive_name "LLM Users Schedule"
  generic_name :Schedule
  description %(provides calendaring functions to a LLM)

  default_settings({
    platform:        "office365", # or "google"
    email_domain:    "org.com",
    conference_type: "teamsForBusiness",

    # fallback if there isn't one on the zone
    time_zone: "Australia/Sydney",
  })

  @platform : String = "office365"
  @email_domain : String = "org.com"
  @conference_type : String? = "teamsForBusiness"
  @fallback_timezone : Time::Location = Time::Location::UTC

  def on_load
    on_update
  end

  def on_update
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @fallback_timezone = Time::Location.load(timezone)
    @platform = setting?(String, :platform) || "office365"
    @email_domain = setting?(String, :email_domain) || "org.com"
    @conference_type = setting?(String, :conference_type)
  end

  # =========================
  # The LLM Interface
  # =========================

  getter capabilities : String do
    String.build do |str|
      str << "lookup or search for the email and phone numbers of other staff members if you haven't been provided their details. Do not guess.\n"
      str << "provides details of my daily schedule, meeting room bookings and events I'm attending.\n"
      str << "meeting room bookings must have a resource as an attendee.\n"
      str << "my meeting room bookings will have me as the host or creator.\n"
      str << "meeting rooms are the attendees marked as resources.\n"
      str << "all day events may not have an ending time.\n"
      str << "internal staff have the following email domain: #{@email_domain}. We can only obtain the schedules of internal staff\n"
      str << "check schedules before booking or moving meetings to ensure no one is busy at that time\n"
    end
  end

  @[Description("returns my schedule with event details with attendees and their response status. day_offset: 0 will return todays schedule, day_offset: 1 will return tomorrows schedule etc. If you provide a date, in ISO 8601 format and the correct timezone, the date will be used.")]
  def my_schedule(day_offset : Int32 = 0, date : Time? = nil)
    cal_client = place_calendar_client
    me = current_user

    if date
      starting = date.in(timezone).at_beginning_of_day
    else
      now = Time.local(timezone)
      days = day_offset.days
      starting = now.at_beginning_of_day + days
    end
    ending = starting.at_end_of_day

    logger.debug { "requesting events for #{me.name} (#{me.email}) @ #{starting} -> #{ending}" }

    events = cal_client.list_events(me.email, period_start: starting, period_end: ending)
    events = Array(Event).from_json(events.to_json)
    events.each { |event| event.configure_times(timezone) }

    events
  end

  @[Description("search for a staff members phone and email addresses using odata filter queries, don't include `$filter=`, for example: `givenName eq 'mary' or startswith(surname,'smith')`, confrim with the user when there are multiple results, search for both givenName and surname using `or` if there is ambiguity")]
  def search_staff_member(filter : String)
    logger.debug { "searching for staff member: #{filter}" }
    cal_client = place_calendar_client
    cal_client.list_users(filter: filter)
  end

  @[Description("look up a staff members name and phone number by providing their email address. Use search if you only have their name")]
  def lookup_staff_member(email : String)
    logger.debug { "looking up staff member: #{email}" }
    cal_client = place_calendar_client
    user = cal_client.get_user_by_email(email)
    return "could not find a staff member with email #{email}. Try searching for their name?" unless user
    user
  end

  @[Description("returns busy periods of the emails specified. Search for staff first if you haven't been given their email address. This can be a person or a resource like a room. An empty schedules array means they are available")]
  def get_schedules(emails : Array(String), day_offset : Int32 = 0, date : Time? = nil)
    cal_client = place_calendar_client
    me = current_user

    if date
      starting = date.in(timezone).at_beginning_of_day
    else
      now = Time.local(timezone)
      days = day_offset.days
      starting = now.at_beginning_of_day + days
    end
    ending = starting.at_end_of_day
    return "past schedules are not useful" if ending < Time.utc

    duration = ending - starting

    logger.debug { "getting schedules for #{emails} @ #{starting} -> #{ending}" }

    availability_view_interval = {duration, 30.minutes}.min.total_minutes.to_i!

    # format the data that helps the LLM make sense of it
    tz = timezone
    cal_client.get_availability(me.email, emails, starting, ending, view_interval: availability_view_interval).map do |avail|
      {
        email:    avail.calendar,
        schedule: avail.availability.map do |sched|
          {
            status:   sched.status,
            starting: sched.starts_at.in(tz),
            ending:   sched.ends_at.in(tz),
          }
        end,
      }
    end
  end

  @[Description("create a calendar entry with the provided event details. Make sure the attendees are available by getting their schedules first, remember to include the host in the attendees list. An ending time is required except for all day bookings. You can specify an alternate host if booking on behalf of someone else. Don't provide a response_status for attendees when using this function. Starting and ending date times must be ISO 8601 formatted with the timezone")]
  def create(event : CreateEvent)
    cal_client = place_calendar_client
    me = current_user
    my_email = me.email.downcase
    host_email = (event.host.presence || me.email).downcase
    i_am_host = host_email == my_email
    host_name = host_email

    attendees = event.attendees.uniq.reject do |attendee|
      attend_email = attendee.email.downcase
      if attend_email == host_email
        host_name = attendee.name
        true
      elsif attend_email == my_email
        attendee.organizer = true
        false
      end
    end
    attendees << PlaceCalendar::Event::Attendee.new(name: i_am_host ? me.name : host_name, email: host_email, response_status: "accepted", organizer: i_am_host)

    return "error: ending time required unless this is an all_day event" if event.ending.nil? && event.all_day == false

    # create the calendar event
    new_event = PlaceCalendar::Event.new
    new_event.attendees = attendees
    new_event.title = event.title
    new_event.location = event.location
    new_event.all_day = event.all_day
    new_event.event_start = event.starting.in(timezone)
    new_event.event_end = event.ending.try &.in(timezone)
    new_event.body = event.title
    new_event.timezone = timezone.name
    new_event.creator = my_email
    new_event.host = host_email

    logger.debug { "creating booking: #{new_event.inspect}" }

    # convert to the simplified view
    created_event = cal_client.create_event(user_id: my_email, event: new_event, calendar_id: host_email)
    Event.from_json(created_event.to_json).configure_times(timezone)
  end

  @[Description("update the details of an existing event. The original id is required, otherwise you only need to provide the changes. You must provide the complete list of attendees if that list is being modified. Don't provide a response_status for attendees when using this function. You can't modify events where the start time is in the past")]
  def modify(event : UpdateEvent)
    cal_client = place_calendar_client
    me = current_user

    # fetch existing event
    existing = cal_client.get_event(me.email, id: event.id)
    return "error: could not find event with id '#{event.id}', it may have been cancelled?" unless existing

    # update with these new details
    {% for param in %w(title location host attendees) %}
      existing.{{param.id}} = event.{{param.id}}.nil? ? existing.{{param.id}} : event.{{param.id}}.not_nil!
    {% end %}

    existing.event_start = event.starting.nil? ? existing.event_start.in(timezone) : event.starting.not_nil!.in(timezone)
    if event.all_day
      existing.all_day = true
      existing.event_end = nil
    else
      existing.all_day = false
      existing.event_end = event.ending.nil? ? existing.event_end.try(&.in(timezone)) : event.ending.not_nil!.in(timezone)
      return "error: ending time required unless this is an all_day event" if event.ending.nil? && event.all_day == false
    end

    logger.debug { "updating event: #{existing.inspect}" }

    # update the event
    updated_event = cal_client.update_event(user_id: me.email, event: existing, calendar_id: existing.host)
    Event.from_json(updated_event.to_json).configure_times(timezone)
  end

  @[Description("cancels an event with an optional reason")]
  def cancel(event_id : String, reason : String? = nil)
    cal_client = place_calendar_client
    me = current_user

    logger.debug { "declining event: #{event_id}" }

    cal_client.decline_event(
      user_id: me.email,
      id: event_id,
      notify: !!reason,
      comment: reason
    )

    "cancelled"
  end

  enum Attendance
    Attend
    Decline
  end

  @[Description("use to confirm your attendance at a meeting this will update your attendee response_status in the specified meeting from your schedule. You should probably provide a reason when declining, however this is optional")]
  def update_attending_status(event_id : String, attendance : Attendance, reason : String? = nil)
    cal_client = place_calendar_client
    me = current_user

    logger.debug { "updating attendance: #{attendance} #{reason} -> #{event_id}" }

    case attendance
    in .decline?
      cal_client.decline_event(
        user_id: me.email,
        id: event_id,
        notify: true,
        comment: reason
      )

      "declined"
    in .attend?
      cal_client.accept_event(
        user_id: me.email,
        id: event_id,
        notify: true,
        comment: reason
      )

      "attending"
    end
  end

  # =========================
  # Support functions
  # =========================

  struct CreateEvent
    include JSON::Serializable

    getter title : String
    getter location : String?
    getter host : String?
    getter attendees : Array(PlaceCalendar::Event::Attendee) = [] of PlaceCalendar::Event::Attendee
    getter starting : Time
    getter ending : Time?
    getter all_day : Bool = false
  end

  struct UpdateEvent
    include JSON::Serializable

    getter id : String
    getter title : String?
    getter location : String?
    getter host : String?
    getter attendees : Array(PlaceCalendar::Event::Attendee)?
    getter starting : Time?
    getter ending : Time?
    getter all_day : Bool?
  end

  class Event
    include JSON::Serializable

    getter id : String?
    getter title : String?
    getter location : String?
    getter status : String?
    getter host : String?
    getter creator : String?
    getter all_day : Bool
    getter attendees : Array(PlaceCalendar::Event::Attendee)
    getter online_meeting_url : String?

    # We convert unix time into something more readable for a human or AI
    @[JSON::Field(converter: Time::EpochConverter, type: "integer", format: "Int64", ignore_serialize: true)]
    getter event_start : Time

    @[JSON::Field(converter: Time::EpochConverter, type: "integer", format: "Int64", ignore_serialize: true)]
    getter event_end : Time?

    getter starting : Time?
    getter ending : Time?

    # these are used to configure the JSON times correctly
    @[JSON::Field(ignore_serialize: true)]
    getter timezone : String?

    @[JSON::Field(ignore: true)]
    getter! time_zone : Time::Location

    def configure_times(tz : Time::Location)
      @time_zone = tz
      @starting = event_start.in(tz)
      @ending = event_end.try &.in(tz)
      self
    end
  end

  struct User
    include JSON::Serializable

    getter name : String
    getter email : String
  end

  protected def staff_api
    system["StaffAPI_1"]
  end

  def current_user : User
    User.from_json staff_api.user(invoked_by_user_id).get.to_json
  end

  getter timezone : Time::Location do
    building.time_zone || @fallback_timezone
  end

  struct Zone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?

    @[JSON::Field(key: "timezone")]
    getter tz : String?

    @[JSON::Field(ignore: true)]
    getter time_zone : Time::Location? do
      if tz = @tz.presence
        Time::Location.load(tz)
      end
    end
  end

  getter building : Zone { get_building }

  # Finds the building ID for the current location services object
  def get_building : Zone
    zones = staff_api.zones(tags: "building").get.as_a
    zone_ids = zones.map(&.[]("id").as_s)
    building_id = (zone_ids & system.zones).first

    building = zones.find! { |zone| zone["id"].as_s == building_id }
    Zone.from_json building.to_json
  rescue error
    msg = "unable to determine building zone"
    logger.warn(exception: error) { msg }
    raise msg
  end

  record AccessToken, token : String, expires : Int64? { include JSON::Serializable }

  protected def get_users_access_token
    AccessToken.from_json staff_api.user_resource_token.get.to_json
  end

  protected def place_calendar_client : ::PlaceCalendar::Client
    token = get_users_access_token

    case @platform
    when "office365"
      cal = ::PlaceCalendar::Office365.new(token.token, @conference_type, delegated_access: true)
      ::PlaceCalendar::Client.new(cal)
    when "google"
      auth = ::Google::TokenAuth.new(token.token, token.expires || 5.hours.from_now.to_unix)
      cal = ::PlaceCalendar::Google.new(auth, @email_domain, conference_type: @conference_type, delegated_access: true)
      ::PlaceCalendar::Client.new(cal)
    else
      raise "unknown platform: #{@platform}, expecting google or office365"
    end
  end
end
