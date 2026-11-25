require "placeos-driver"
require "place_calendar"
require "uuid"

# An in-memory calendar with the interface of `Place::Calendar`, for systems
# that have no Google or Microsoft tenant behind them: demo instances and end
# to end test stacks. `Place::Bookings` runs against it unchanged.
#
# Events exist only while the module runs. Nothing is sent to a mailbox.
class Place::Demo::Calendar < PlaceOS::Driver
  descriptive_name "Demo Calendar"
  generic_name :Calendar
  description %(an in-memory stand-in for the PlaceOS Calendar driver. Events \
are kept in the module and nothing reaches a real mailbox. For demo systems \
and end to end testing.)

  default_settings({
    # the directory `list_users` and `get_user` answer from
    users: [
      {name: "Demo User", email: "demo.user@example.com"},
    ],
  })

  alias Event = ::PlaceCalendar::Event
  alias Attendee = ::PlaceCalendar::Event::Attendee
  alias User = ::PlaceCalendar::User

  # calendar id (lower case) => event id => event
  @calendars = {} of String => Hash(String, Event)
  @users = [] of User

  def on_update
    @users = setting?(Array(User), :users) || [] of User
    publish_counts
  end

  # ---------------------------------------------------------------------------
  # Directory

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_users(
    query : String? = nil,
    limit : Int32? = nil,
    filter : String? = nil,
    next_page : String? = nil,
    additional_fields : Array(String)? = nil,
  )
    users = @users
    if term = query.presence.try(&.downcase)
      users = users.select do |user|
        user.name.to_s.downcase.includes?(term) || user.email.to_s.downcase.includes?(term)
      end
    end
    limit ? users.first(limit) : users
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_user(user_id : String, additional_fields : Array(String)? = nil)
    id = user_id.downcase
    @users.find { |user| user.email.to_s.downcase == id || user.id == user_id }
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_calendars(user_id : String)
    [::PlaceCalendar::Calendar.new(user_id.downcase, user_id, primary: true, can_edit: true)]
  end

  # ---------------------------------------------------------------------------
  # Events

  @[PlaceOS::Driver::Security(Level::Support)]
  def list_events(
    calendar_id : String,
    period_start : Int64,
    period_end : Int64,
    time_zone : String? = nil,
    user_id : String? = nil,
    include_cancelled : Bool = false,
    ical_uid : String? = nil,
  )
    starting = Time.unix(period_start)
    ending = Time.unix(period_end)

    events = stored_on(calendar_id).values.select do |event|
      next false if !include_cancelled && event.status == "cancelled"
      next false if ical_uid && event.ical_uid != ical_uid
      event.event_start < ending && ends_at(event) > starting
    end
    events.sort_by(&.event_start)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def get_event(calendar_id : String, event_id : String, user_id : String? = nil)
    stored_on(calendar_id)[event_id]?
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def create_event(
    title : String,
    event_start : Int64,
    event_end : Int64? = nil,
    description : String = "",
    attendees : Array(Attendee) = [] of Attendee,
    location : String? = nil,
    timezone : String? = nil,
    user_id : String? = nil,
    calendar_id : String? = nil,
    online_meeting_id : String? = nil,
    online_meeting_provider : String? = nil,
    online_meeting_url : String? = nil,
    online_meeting_sip : String? = nil,
    online_meeting_phones : Array(String)? = nil,
    online_meeting_pin : String? = nil,
  )
    user_id = (user_id || calendar_id).not_nil!
    calendar_id = calendar_id || user_id
    now = Time.utc
    tz = timezone ? Time::Location.load(timezone) : Time::Location::UTC

    event = Event.new(
      id: UUID.random.to_s,
      host: calendar_id,
      title: title,
      body: description,
      location: location,
      timezone: timezone,
      attendees: attendees,
      online_meeting_id: online_meeting_id,
      online_meeting_url: online_meeting_url,
      online_meeting_sip: online_meeting_sip,
      online_meeting_pin: online_meeting_pin,
      online_meeting_phones: online_meeting_phones,
      online_meeting_provider: online_meeting_provider,
    )
    event.event_start = Time.unix(event_start).in(tz)
    event.event_end = Time.unix(event_end).in(tz) if event_end
    event.all_day = event_end.nil?
    event.status = "confirmed"
    event.creator = user_id
    event.ical_uid = UUID.random.to_s
    event.created = now
    event.updated = now

    store(event, calendar_id)
    event
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def update_event(event : Event, user_id : String? = nil, calendar_id : String? = nil)
    id = event.id || raise "event has no id"
    holders = calendars_holding(id)
    raise "event #{id} not found" if holders.empty?

    event.updated = Time.utc
    holders.each { |cal| @calendars[cal][id] = event }
    publish_counts
    event
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    calendars_holding(event_id).each { |cal| @calendars[cal].delete(event_id) }
    publish_counts
    nil
  end

  # Removes the event from this calendar only, as a declined invitation leaves
  # the organiser's copy in place.
  @[PlaceOS::Driver::Security(Level::Support)]
  def decline_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    events_on(calendar_id).delete(event_id)
    respond(calendar_id, event_id, "declined")
    publish_counts
    nil
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def accept_event(calendar_id : String, event_id : String, user_id : String? = nil, notify : Bool = false, comment : String? = nil)
    respond(calendar_id, event_id, "accepted")
    nil
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def clear_events(calendar_id : String? = nil)
    if calendar_id
      @calendars.delete(calendar_id.downcase)
    else
      @calendars.clear
    end
    publish_counts
    nil
  end

  def calendar_service_name
    "demo"
  end

  # ---------------------------------------------------------------------------

  protected def events_on(calendar_id : String) : Hash(String, Event)
    @calendars[calendar_id.downcase] ||= {} of String => Event
  end

  EMPTY = {} of String => Event

  protected def stored_on(calendar_id : String) : Hash(String, Event)
    @calendars[calendar_id.downcase]? || EMPTY
  end

  protected def ends_at(event : Event) : Time
    event.event_end || event.event_start + 1.day
  end

  protected def calendars_holding(event_id : String) : Array(String)
    @calendars.compact_map { |cal, events| cal if events.has_key?(event_id) }
  end

  # The organiser's calendar and every attendee's calendar hold the same event,
  # as they do after a real invitation is sent.
  protected def store(event : Event, calendar_id : String)
    id = event.id.not_nil!
    events_on(calendar_id)[id] = event
    event.attendees.each { |attendee| events_on(attendee.email)[id] = event }
    publish_counts
  end

  # `Attendee` is a struct, so the list is rebuilt rather than edited in place.
  protected def respond(calendar_id : String, event_id : String, response : String)
    email = calendar_id.downcase
    calendars_holding(event_id).each do |cal|
      event = @calendars[cal][event_id]
      event.attendees = event.attendees.map do |attendee|
        next attendee unless attendee.email.downcase == email
        Attendee.new(attendee.name, attendee.email, response, attendee.resource, attendee.organizer)
      end
    end
  end

  protected def publish_counts
    self[:calendars] = @calendars.transform_values(&.size)
  end
end
