require "placeos-driver"

class Place::BookingApprover < PlaceOS::Driver
  descriptive_name "Booking Auto Approver"
  generic_name :BookingApprover
  description %(Automatically approves all PlaceOS bookings)

  accessor staff_api : StaffAPI_1

  default_settings({
    # approve_booking_types: ["desk"],   Todo: only approve selected booking types
    debug: false,
  })

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      approve_booking(Booking.from_json payload)
    end
    on_update
  end

  @debug : Bool = false
  @bookings_approved : Int32 = 0u32

  def on_update
    @debug = setting(Bool, :debug)
  end

  class Booking
    include JSON::Serializable

    property id : Int64

    property user_id : String
    property user_email : String
    property user_name : String
    property asset_id : String
    property zones : Array(String)
    property booking_type : String

    property booking_start : Int64
    property booking_end : Int64

    property timezone : String?
    property title : String?
    property description : String?

    property checked_in : Bool
    property rejected : Bool
    property approved : Bool

    property approver_id : String?
    property approver_email : String?
    property approver_name : String?

    property booked_by_id : String
    property booked_by_email : String
    property booked_by_name : String

    property process_state : String?
    property last_changed : Int64?
    property created : Int64?
  end

  private def approve_booking(booking : Booking)
    staff_api.approve(booking.id).get
    @bookings_approved += 1
    logger.debug { "Approved Booking #{booking.id}" } if @debug
  end

  def status
    {bookings_approved: @bookings_approved}
  end
end
