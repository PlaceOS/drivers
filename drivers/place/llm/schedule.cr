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
  @conference_type : String = "office365"
  @fallback_timezone : Time::Location = Time::Location::UTC

  def on_load
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @fallback_timezone = Time::Location.load(timezone)
    @platform = setting?(String, :platform) || "office365"
    @email_domain = setting?(String, :email_domain) || "org.com"
    @conference_type = setting?(String, :conference_type) || "teamsForBusiness"
  end

  # =========================
  # The LLM Interface
  # =========================

  getter capabilities : String do
    String.build do |str|
      str << "details of my daily schedule, meeting room bookings and events I'm attending.\n"
      str << "meeting room bookings must have a resource as an attendee.\n"
      str << "my meeting room bookings will have me as the host or creator.\n"
      str << "meeting rooms are the attendees marked as resources.\n"
      str << "all day events may not have an ending time.\n"
    end
  end

  @[Description("returns my schedule with event details. day_offset: 0 will return todays schedule, day_offset: 1 will return tomorrows schedule etc.")]
  def my_schedule(day_offset : Int32 = 0)
    cal_client = place_calendar_client
    me = current_user

    now = Time.local(timezone)
    days = day_offset.days
    starting = now.at_beginning_of_day + days
    ending = now.at_end_of_day + days

    logger.debug { "requesting events for #{me.name} (#{me.email}) @ #{starting} -> #{ending}" }

    events = cal_client.list_events(me.email, period_start: starting, period_end: ending)
    events = Array(Event).from_json(events.to_json)
    events.each { |event| event.configure_times(timezone) }

    events
  end

  @[Description("returns free busy times of the email specified. This can be a person or a resource like a room")]
  def get_schedule(emails : Array(String), day_offset : Int32 = 0)
    nil
  end

  # =========================
  # Support functions
  # =========================

  struct Event
    include JSON::Serializable

    getter title : String?
    getter location : String?
    getter status : String?
    getter host : String?
    getter creator : String?
    getter all_day : Bool
    getter recurring : Bool = false
    getter attendees : Array(PlaceCalendar::Event::Attendee)
    getter online_meeting_url : String?

    # We convert unix time into something more readable for a human or AI
    @[JSON::Field(converter: Time::EpochConverter, type: "integer", format: "Int64", ignore_serialize: true)]
    getter event_start : Time

    @[JSON::Field(converter: Time::EpochConverter, type: "integer", format: "Int64", ignore_serialize: true)]
    getter event_end : Time?

    @[JSON::Field(ignore_deserialize: true)]
    getter starting : Time { event_start.in(time_zone) }

    @[JSON::Field(ignore_deserialize: true)]
    getter ending : Time? { event_end.try &.in(time_zone) }

    # these are used to configure the JSON times correctly
    @[JSON::Field(ignore_serialize: true)]
    getter timezone : String?

    @[JSON::Field(ignore: true)]
    getter! time_zone : Time::Location

    def configure_times(tz : Time::Location)
      @time_zone = tz
      starting
      ending
    end
  end

  # struct System
  #  include JSON::Serializable
  # end

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
