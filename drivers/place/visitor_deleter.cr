require "placeos-driver"

class Place::VisitorDeleter < PlaceOS::Driver
  descriptive_name "PlaceOS Visitor Deleter"
  generic_name :VisitorDeleter
  description %(Delete guests / visitor bookings n days after their visit. For use with Trigger on cron. Requires Support permissions)

  default_settings({
    building_zone_id: "required",
    debug:            false,
  })

  accessor staff_api : StaffAPI_1

  @building_zone_id : String = "required"

  def on_load
    on_update
  end

  def on_update
    @building_zone_id = setting(String, :building_zone_id)
  end

  @[Security(Level::Support)]
  def find_and_delete(past_days_to_search : UInt32 = 70_u32,
                      days_after_visit_until_visitor_deletion : UInt32 = 60_u32,
                      delete_guests : Bool = true,
                      delete_visitor_bookings : Bool = true) : Nil
    now = Time.utc.to_unix
    from_epoch = now - past_days_to_search.days.to_i
    til_epoch = now - days_after_visit_until_visitor_deletion.days.to_i

    find_and_delete_guests(from_epoch, til_epoch) if delete_guests
    find_and_delete_visitor_bookings(from_epoch, til_epoch) if delete_visitor_bookings
  end

  private def find_and_delete_guests(from_epoch : Int64, til_epoch : Int64)
    guests = staff_api.query_guests(from_epoch, til_epoch, [@building_zone_id]).get.as_a
    guests.each { |g| delete_guest(g["id"].as_i) }
  end

  private def find_and_delete_visitor_bookings(from_epoch : Int64, til_epoch : Int64)
    visitor_bookings = staff_api.query_bookings("visitor", from_epoch, til_epoch, [@building_zone_id]).get.as_a
    visitor_bookings.each { |b| delete_visitor_booking(b["id"].as_i) }
  end

  private def delete_guest(id : Int32)
    staff_api.delete_guest(id)
  end

  private def delete_visitor_booking(id : Int32)
    staff_api.booking_delete(id)
  end
end
