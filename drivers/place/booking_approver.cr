require "placeos-driver"
require "./booking_model"

class Place::BookingApprover < PlaceOS::Driver
  descriptive_name "Booking Auto Approver"
  generic_name :BookingApprover
  description %(Automatically approves all PlaceOS bookings)

  accessor staff_api : StaffAPI_1

  default_settings({
    approve_booking_types: ["desk"],
    approve_zones:         ["zone-12345"],
  })

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      approve_booking(Booking.from_json payload)
    end
    on_update
  end

  @bookings_approved : Int32 = 0u32
  @approve_zones : Array(String) = [] of String
  @approve_booking_types : Array(String) = [] of String

  def on_update
    @approve_zones = setting?(Array(String), :approve_zones) || [] of String
    @approve_booking_types = setting?(Array(String), :approve_booking_types) || [] of String

    schedule.clear
    schedule.every(10.minutes) { approve_missed }
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  private def approve_booking(booking : Booking)
    if !@approve_zones.empty?
      if (booking.zones & @approve_zones).empty?
        logger.debug { "Ignoring booking as no booking zone matches #{booking.id}" }
        return false
      end
    end

    if !@approve_booking_types.empty?
      if !@approve_booking_types.includes?(booking.booking_type)
        logger.debug { "Ignoring booking as booking_type #{booking.booking_type} doesn't match #{booking.id}" }
        return false
      end
    end

    if booking.action == "create" || !booking.approved
      staff_api.approve(booking.id).get
      logger.debug { "Approved Booking #{booking.id}" }
      @bookings_approved += 1
      true
    else
      false
    end
  end

  def approve_missed
    booking_type = @approve_booking_types[0]? || "desk"

    bookings = Array(Booking).from_json staff_api.query_bookings(
      type: booking_type,
      zones: [get_building_id],
      approved: false,
      period_end: 8.weeks.from_now.to_unix
    ).get.to_json

    bookings.each do |booking|
      booking.action = "create"
      approve_booking booking
    end

    "found #{bookings.size} missed"
  end

  def status
    {bookings_approved: @bookings_approved}
  end
end
