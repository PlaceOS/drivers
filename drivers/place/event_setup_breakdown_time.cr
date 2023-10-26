require "placeos-driver"
require "place_calendar"

class Place::EventSetupBreakdownTime < PlaceOS::Driver
  descriptive_name "PlaceOS Event Setup/Breakdown Time"
  generic_name :EventSetupBreakdownTime
  description %(Manages setup/breakdown time before/after events)

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1

  @event_change_mutex : Mutex = Mutex.new

  def on_load
    monitor("staff/event/changed") do |_subscription, payload|
      begin
        logger.debug { "received event changed signal #{payload}" }

        @event_change_mutex.synchronize do
          event_changed(EventChangedSignal.from_json(payload))
        end
      rescue error
        logger.warn(exception: error) { "error processing event changed signal" }
      end
    end

    on_update
  end

  def on_update
  end

  private def event_changed(signal : EventChangedSignal)
    system_id = signal.system_id
    event = signal.event
    calendar_id = signal.resource
    cancelled = event.status == "cancelled" || signal.action == "cancelled"

    # delete setup/breakdown events if event is cancelled
    if cancelled
      if setup_event_id = event.setup_event_id
        calendar.delete_event(
          calendar_id: calendar_id,
          event_id: setup_event_id,
        )
        logger.debug { "deleted setup event #{setup_event_id}" }
      end
      if breakdown_event_id = event.breakdown_event_id
        calendar.delete_event(
          calendar_id: calendar_id,
          event_id: breakdown_event_id,
        )
        logger.debug { "deleted breakdown event #{breakdown_event_id}" }
      end
      return
    end

    # skip if no changes
    if meta = Array(EventMetadata).from_json(staff_api.query_metadata(system_id: system_id, event_ref: [signal.event_id, signal.event_ical_uid]).get.to_json).first?
      if meta.setup_time == event.setup_time &&
         meta.setup_event_id == event.setup_event_id &&
         (
           (meta.setup_time > 0 && meta.setup_event_id) ||
           (meta.setup_time == 0 && !meta.setup_event_id.presence)
         ) &&
         meta.breakdown_time == event.breakdown_time &&
         meta.breakdown_event_id == event.breakdown_event_id &&
         (
           (meta.breakdown_time > 0 && meta.breakdown_event_id) ||
           (meta.breakdown_time == 0 && !meta.breakdown_event_id.presence)
         )
        logger.debug { "skipping event #{signal.event_id} on #{calendar_id} as no changes" }
        return
      end
    end

    raise "missing event_start time" unless event_start = event.event_start
    raise "missing event_end time" unless event_end = event.event_end

    linked_events = LinkedEvents.new(main_event_ical: event.ical_uid, main_event_id: event.id)
    linked_events.setup_event_id = event.setup_event_id if event.setup_event_id
    linked_events.breakdown_event_id = event.breakdown_event_id if event.breakdown_event_id

    linked_events = LinkedEvents.new(main_event_ical: event.ical_uid, main_event_id: event.id)
    linked_events.setup_event_id = event.setup_event_id if event.setup_event_id
    linked_events.breakdown_event_id = event.breakdown_event_id if event.breakdown_event_id

    # create/update setup event
    if (setup_time = event.setup_time) && setup_time > 0
      if setup_event_id = event.setup_event_id
        setup_event = PlaceCalendar::Event.from_json calendar.get_event(calendar_id: calendar_id, event_id: setup_event_id).get.to_json
        setup_event.event_start = event_start - setup_time.minutes
        setup_event.event_end = event_start
        setup_event.body = "<<<#{linked_events.to_json}}>>>"
        calendar.update_event(event: setup_event, calendar_id: calendar_id)
        logger.debug { "updated setup event #{setup_event_id} on #{calendar_id}" }
      else
        setup_event = PlaceCalendar::Event.from_json calendar.create_event(
          calendar_id: calendar_id,
          title: "Setup for #{event.title}",
          event_start: (event_start - setup_time.minutes).to_unix,
          event_end: event_start.to_unix,
          description: "<<<#{linked_events.to_json}}>>>",
          attendees: [PlaceCalendar::Event::Attendee.new(name: calendar_id, email: calendar_id, response_status: "accepted", resource: true, organizer: true)],
        ).get.to_json

        linked_events.setup_event_id = setup_event.id
        logger.debug { "created setup event #{setup_event.id} on #{calendar_id}" }
        event.setup_event_id = setup_event.id
      end
    elsif (setup_time = event.setup_time) && (setup_event_id = event.setup_event_id) && setup_time == 0
      calendar.delete_event(
        calendar_id: calendar_id,
        event_id: setup_event_id,
      )
      logger.debug { "deleted setup event #{setup_event_id} on #{calendar_id}" }
      event.setup_event_id = ""
    end

    # create/update breakdown event
    if (breakdown_time = event.breakdown_time) && breakdown_time > 0
      if breakdown_event_id = event.breakdown_event_id
        breakdown_event = PlaceCalendar::Event.from_json calendar.get_event(calendar_id: calendar_id, event_id: breakdown_event_id).get.to_json
        breakdown_event.event_start = event_end
        breakdown_event.event_end = event_end + breakdown_time.minutes
        breakdown_event.body = "<<<#{linked_events.to_json}}>>>"
        calendar.update_event(event: breakdown_event, calendar_id: calendar_id)
        logger.debug { "updated breakdown event #{breakdown_event_id} on #{calendar_id}" }
      else
        breakdown_event = PlaceCalendar::Event.from_json calendar.create_event(
          calendar_id: calendar_id,
          title: "Breakdown for #{event.title}",
          event_start: event_end.to_unix,
          event_end: (event_end + breakdown_time.minutes).to_unix,
          description: "<<<#{linked_events.to_json}}>>>",
          attendees: [PlaceCalendar::Event::Attendee.new(name: calendar_id, email: calendar_id, response_status: "accepted", resource: true, organizer: true)],
        ).get.to_json

        logger.debug { "created breakdown event #{breakdown_event.id} on #{calendar_id}" }
        event.breakdown_event_id = breakdown_event.id
      end
    elsif (breakdown_time = event.breakdown_time) && (breakdown_event_id = event.breakdown_event_id) && breakdown_time == 0
      calendar.delete_event(
        calendar_id: calendar_id,
        event_id: breakdown_event_id,
      )
      logger.debug { "deleted breakdown event #{breakdown_event_id} on #{calendar_id}" }
      event.breakdown_event_id = ""
    end

    # save metadata
    staff_api.patch_event_metadata(system_id: system_id, event_id: signal.event_id, metadata: NamedTuple.new, ical_uid: signal.event_ical_uid, setup_time: event.setup_time, breakdown_time: event.breakdown_time, setup_event_id: event.setup_event_id, breakdown_event_id: event.breakdown_event_id).get
  end

  class PlaceCalendar::Event
    property setup_time : Int64? = nil
    property breakdown_time : Int64? = nil
    property setup_event_id : String? = nil
    property breakdown_event_id : String? = nil
  end

  struct LinkedEvents
    include JSON::Serializable

    property main_event_ical : String?
    property main_event_id : String?
    property setup_event_id : String?
    property breakdown_event_id : String?

    def initialize(@main_event_ical : String?, @main_event_id : String?)
    end
  end

  struct LinkedEvents
    include JSON::Serializable

    property main_event_ical : String?
    property main_event_id : String?
    property setup_event_id : String?
    property breakdown_event_id : String?

    def initialize(@main_event_ical : String?, @main_event_id : String?)
    end
  end

  struct EventChangedSignal
    include JSON::Serializable

    property action : String
    property system_id : String
    property event_id : String
    property event_ical_uid : String
    property host : String?
    property resource : String
    property event : PlaceCalendar::Event
    property ext_data : JSON::Any?
  end

  struct EventMetadata
    include JSON::Serializable

    property system_id : String
    property event_id : String
    property recurring_master_id : String?
    property ical_uid : String

    property host_email : String
    property resource_calendar : String
    property event_start : Int64
    property event_end : Int64
    property cancelled : Bool = false

    property ext_data : JSON::Any?

    property setup_time : Int64 = 0
    property breakdown_time : Int64 = 0
    property setup_event_id : String?
    property breakdown_event_id : String?
  end
end
