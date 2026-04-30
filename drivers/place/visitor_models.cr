require "json"

module Place
  enum Induction
    TENTATIVE
    ACCEPTED
    DECLINED
  end

  abstract class GuestNotification
    include JSON::Serializable

    use_json_discriminator "action", {
      "booking_created"    => BookingGuest,
      "booking_updated"    => BookingGuest,
      "meeting_created"    => EventGuest,
      "meeting_update"     => EventGuest,
      "checkin"            => GuestCheckin,
      "induction_accepted" => BookingInduction,
      "induction_declined" => BookingInduction,
    }

    property action : String

    property checkin : Bool?
    property event_title : String?
    property event_summary : String
    property event_starting : Int64
    property attendee_name : String?
    property attendee_email : String
    property host : String

    # This is optional for backwards compatibility
    property zones : Array(String)?

    property ext_data : Hash(String, JSON::Any)?
  end

  class EventGuest < GuestNotification
    include JSON::Serializable

    property system_id : String
    property event_id : String
    property resource : String

    def resource_id
      system_id
    end
  end

  class BookingGuest < GuestNotification
    include JSON::Serializable

    property booking_id : Int64
    property resource_id : String

    def event_id
      booking_id.to_s
    end
  end

  class GuestCheckin < GuestNotification
    include JSON::Serializable

    property system_id : String = ""
    property event_id : String = ""
    property resource : String = ""
    property resource_id : String = ""
  end

  class BookingInduction < GuestNotification
    include JSON::Serializable

    property induction : Induction = Induction::TENTATIVE
    property booking_id : Int64
    property resource_id : String
    property resource_ids : Array(String)

    def event_id
      booking_id.to_s
    end
  end

  # Standalone model for the staff/booking/host_changed channel.
  # Not a GuestNotification subclass because it has no attendee — it targets
  # the previous host directly.
  class BookingHostChanged
    include JSON::Serializable

    property action : String
    property booking_id : Int64
    property resource_id : String
    property resource_ids : Array(String)
    property event_title : String?
    property event_summary : String
    property event_starting : Int64
    property previous_host_email : String
    property new_host_email : String
    property zones : Array(String)?

    def event_id
      booking_id.to_s
    end
  end

  # Standalone model for the staff/booking/changed channel.
  # Used to notify visitors when booking details they care about have changed.
  class BookingChanged
    include JSON::Serializable

    property action : String
    property id : Int64
    property booking_type : String
    property booking_start : Int64
    property booking_end : Int64
    property timezone : String?
    property resource_id : String
    property resource_ids : Array(String)
    property user_email : String
    property title : String?
    property zones : Array(String)?

    # Previous values — only present when action is "changed".
    # Add new previous_* fields here as more change notifications are introduced.
    property previous_booking_start : Int64?
    property previous_booking_end : Int64?
    property previous_zones : Array(String)?
  end

  # Standalone model for the staff/event/changed channel.
  # Used to notify visitors when calendar event details they care about have changed.
  class EventChanged
    include JSON::Serializable

    property action : String
    property system_id : String
    property event_id : String
    property event_ical_uid : String?
    property host : String
    property resource : String?
    property title : String?
    property event_start : Int64
    property event_end : Int64
    property zones : Array(String)?

    # Previous values — only present when action is "update" and the meta was persisted.
    property previous_event_start : Int64?
    property previous_event_end : Int64?
    property previous_system_id : String?
    property previous_host_email : String?
  end
end
