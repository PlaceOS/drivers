require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::EventAttendanceRecorder" do
  system({
    StaffAPI: {StaffAPIMock},
  })

  # Start a new meeting
  exec(:fetch_and_check_in).get.should eq "checked-in 2 bookings, failed 1: [3]"
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def query_bookings(
    type : String,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil
  )
    [{id: 1}, {id: 2}, {id: 3}]
  end

  def booking_check_in(booking_id : String | Int64, state : Bool = true, utm_source : String? = nil)
    logger.debug { "checking in booking #{booking_id} to: #{state} from #{utm_source}" }

    case booking_id
    when 3
      raise "issue updating booking state #{booking_id}: 404"
    else
      true
    end
  end
end
