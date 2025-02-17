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
end
