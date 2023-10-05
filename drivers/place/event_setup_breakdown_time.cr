require "placeos-driver"
require "place_calendar"

class Place::SurveyMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Event Setup/Breakdown Time"
  generic_name :EventSetupBreakdownTime
  description %(Manages setup/breakdown time before/after events)

  accessor staff_api : StaffAPI_1

  def on_load
    on_update
  end

  def on_update
    monitor("staff/event/changed") do |_subscription, payload|
      logger.debug { "received event changed signal #{payload}" }
      event_changed(EventChangedSignal.from_json(payload))
    end
  end

  private def event_changed(signal : EventChangedSignal)
    system_id = signal.system_id
    event = signal.event
    calendar = event.host || signal.host || signal.resource
    raise "missing event_start time" unless event_start = event.event_start
    raise "missing event_end time" unless event_end = event.event_end
    cancelled = event.status == "cancelled"

    meta = EventMetadata.from_json staff_api.query_metadata(system_id: system_id, event_ref: [signal.event_id, signal.event_ical_uid]).get.to_json

    # create/update setup event
    if meta.setup_time > 0
      if setup_event_id = meta.setup_event_id
        setup_event = PlaceCalendar::Event.from_json staff_api.get_event(event_id: setup_event_id, system_id: system_id, calendar: calendar).get.to_json
        setup_event.event_start = event_start - meta.setup_time.seconds
        setup_event.event_end = event_start
        staff_api.update_event(system_id: system_id, event: setup_event)
        logger.debug { "updated setup event #{setup_event}" }
      else
        setup_event = PlaceCalendar::Event.from_json staff_api.get_event(
          PlaceCalendar::Event.new(
            host: calendar,
            title: "Setup for #{event.title}",
            event_start: event_start - meta.setup_time.seconds,
            event_end: event_start,
          )).get.to_json

        logger.debug { "created setup event #{setup_event}" }
        meta.setup_event_id = setup_event.id
      end
    end

    # create/update breakdown event
    if meta.breakdown_time > 0
      if breakdown_event_id = meta.breakdown_event_id
        breakdown_event = PlaceCalendar::Event.from_json staff_api.get_event(event_id: breakdown_event_id, system_id: system_id, calendar: calendar).get.to_json
        breakdown_event.event_start = event_end
        breakdown_event.event_end = event_end + meta.breakdown_time.seconds
      else
        breakdown_event = PlaceCalendar::Event.from_json staff_api.get_event(
          PlaceCalendar::Event.new(
            host: calendar,
            title: "Breakdown for #{event.title}",
            event_start: event_end,
            event_end: event_end + meta.breakdown_time.seconds,
          )).get.to_json

        logger.debug { "created breakdown event #{breakdown_event}" }
        meta.breakdown_event_id = breakdown_event.id
      end
    end

    # delete setup/breakdown events if event is cancelled
    if cancelled
      if setup_event_id = meta.setup_event_id
        staff_api.delete_event(
          system_id: system_id,
          event_id: setup_event_id,
        ).get
        meta.setup_event_id = nil
      end
      if breakdown_event_id = meta.breakdown_event_id
        staff_api.delete_event(
          system_id: system_id,
          event_id: breakdown_event_id,
        ).get
        meta.breakdown_event_id = nil
      end
    end

    # save metadata
    staff_api.patch_event_metadata(system_id: system_id, event_id: signal.event_id, metadata: meta, ical_uid: signal.event_ical_uid)
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
