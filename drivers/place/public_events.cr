require "placeos-driver"
require "place_calendar"
require "placeos-models"

# Filters Bookings event cache down to public events for unauthenticated access.
# Only includes events where the PlaceOS metadata permission is set to PUBLIC.
# Uses the Calendar driver for guest registration.
class Place::PublicEvents < PlaceOS::Driver
  descriptive_name "PlaceOS Public Events"
  generic_name :PublicEvents
  description %(Caches public events for external access and handles guest registration)

  accessor bookings : Bookings_1
  accessor calendar : Calendar_1

  # the permission field lives in the staff API `EventMetadata` table, it is not
  # part of a calendar event, so it can't be included in the Bookings cache
  accessor staff_api : StaffAPI_1

  alias Permission = PlaceOS::Model::EventMetadata::Permission

  # the number of event references we send to the staff API in a single request,
  # this keeps the query string well below the HTTP request line size limit
  REF_BATCH_SIZE = 50

  default_settings({
    # how often we re-check the event metadata permissions
    metadata_refresh_minutes: 5,
  })

  @all_bookings : Array(PublicEvent) = [] of PublicEvent
  @public_event_ids : Set(String) = Set(String).new
  @filter_mutex : Mutex = Mutex.new

  bind Bookings_1, :bookings, :on_bookings_change

  def on_update
    refresh_minutes = setting?(Int32, :metadata_refresh_minutes) || 5

    # a permission can be changed without the event changing, and the Bookings
    # driver only publishes `bookings` when the events have actually changed,
    # so we can't rely on the subscription alone to keep the cache fresh
    schedule.clear
    schedule.every(refresh_minutes.minutes) { filter_and_cache } if refresh_minutes > 0
  end

  private def on_bookings_change(_subscription, new_value : String)
    @all_bookings = Array(PublicEvent).from_json(new_value)
    filter_and_cache
  rescue error
    logger.warn(exception: error) { "failed to process bookings update" }
  end

  private def filter_and_cache : Array(PublicEvent)
    @filter_mutex.synchronize do
      events = @all_bookings
      logger.debug { "received #{events.size} total events from bookings" }

      permissions = event_permissions(events)

      public_events = events.select do |event|
        # a calendar event marked private has had its title and host masked by
        # the Bookings driver, so there is nothing useful (or safe) to publish
        permission_for(event, permissions).public? && !event.private?
      end

      logger.debug { "#{public_events.size} events have PUBLIC permission" }

      @public_event_ids = public_events.compact_map(&.id).to_set
      self["public_events"] = public_events
      public_events
    end
  end

  # Looks the metadata permission up in the staff API.
  # Returns the instance level permissions and the recurring master permissions
  # separately, so instance metadata can take precedence over the master.
  private def event_permissions(events : Array(PublicEvent)) : Permissions
    by_event = {} of String => Permission
    by_master = {} of String => Permission
    permissions = {by_event, by_master}
    return permissions if events.empty?

    system_id = system.id
    refs = events.flat_map { |event| [event.id, event.ical_uid, event.recurring_event_id] }.compact
    refs.uniq!
    return permissions if refs.empty?

    refs.each_slice(REF_BATCH_SIZE) do |batch|
      metadata(system_id, batch).each do |meta|
        by_event[meta.event_id] = meta.permission
        by_event[meta.ical_uid] = meta.permission

        # only the metadata of the series master applies to the whole series,
        # instances have their own metadata which also references the master
        if (master_id = meta.recurring_master_id) && master_id == meta.event_id
          by_master[master_id] = meta.permission
          if resource_master_id = meta.resource_master_id
            by_master[resource_master_id] = meta.permission
          end
        end
      end
    end

    permissions
  end

  private def metadata(system_id : String, event_ref : Array(String)) : Array(EventMetadata)
    response = staff_api.query_metadata(system_id: system_id, event_ref: event_ref).get
    Array(EventMetadata).from_json(response.to_json)
  end

  private def permission_for(event : PublicEvent, permissions : Permissions) : Permission
    by_event, by_master = permissions

    if (event_id = event.id) && (permission = by_event[event_id]?)
      return permission
    end

    if (ical_uid = event.ical_uid) && (permission = by_event[ical_uid]?)
      return permission
    end

    if (master_id = event.recurring_event_id) && (permission = by_master[master_id]?)
      return permission
    end

    Permission::PRIVATE
  end

  # Forces a Bookings re-poll then re-applies the public filter.
  @[Security(Level::Administrator)]
  def update_public_events : Nil
    bookings.poll_events.get

    # the re-poll only publishes `bookings` if the events have changed, so we
    # always re-apply the filter to pick up metadata permission changes
    filter_and_cache
  end

  # Appends an external attendee to the calendar event.
  def register_attendee(event_id : String, name : String, email : String) : Bool
    unless @public_event_ids.includes?(event_id)
      logger.warn { "#{event_id} is not a known public event" }
      return false
    end

    cal_id = system.email.presence
    unless cal_id
      logger.error { "system has no calendar email configured" }
      return false
    end

    event_data = calendar.get_event(cal_id, event_id).get
    unless event_data
      logger.warn { "event #{event_id} not found in calendar" }
      return false
    end

    event = PlaceCalendar::Event.from_json(event_data.to_json)
    event.attendees << PlaceCalendar::Event::Attendee.new(name: name, email: email)
    calendar.update_event(event, calendar_id: cal_id).get
    true
  end

  alias Permissions = Tuple(Hash(String, Permission), Hash(String, Permission))

  # The subset of the staff API event metadata we require.
  # NOTE:: we don't use `PlaceOS::Model::EventMetadata` as it is a database
  # backed model that renders linked bookings on serialisation.
  private struct EventMetadata
    include JSON::Serializable

    getter event_id : String
    getter ical_uid : String
    getter recurring_master_id : String?
    getter resource_master_id : String?
    getter permission : Permission = Permission::PRIVATE
  end

  # Fields that are safe to expose publicly.
  private struct PublicEvent
    include JSON::Serializable

    getter id : String?
    getter title : String?
    getter body : String?
    getter event_start : Int64
    getter event_end : Int64?
    getter location : String?
    getter timezone : String?
    getter? all_day : Bool = false

    # used for matching metadata and filtering, never exposed publicly
    @[JSON::Field(ignore_serialize: true)]
    getter ical_uid : String? = nil

    @[JSON::Field(ignore_serialize: true)]
    getter recurring_event_id : String? = nil

    @[JSON::Field(ignore_serialize: true)]
    getter? private : Bool = false
  end
end
