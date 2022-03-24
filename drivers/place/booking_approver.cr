require "placeos-driver"
require "./booking_model"

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

  private def approve_booking(booking : Booking)
    return false unless booking.action == "create"
    staff_api.approve(booking.id).get
    @bookings_approved += 1
    logger.debug { "Approved Booking #{booking.id}" } if @debug
    true
  end

  def status
    {bookings_approved: @bookings_approved}
  end
end
