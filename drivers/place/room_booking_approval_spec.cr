require "placeos-driver/spec"
require "./calendar_common"

DriverSpecs.mock_driver "Place::RoomBookingApproval" do
  system({
    Calendar: {CalendarMock},
    Bookings: {BookingsMock},
  })

  _resp = exec(:find_bookings_for_approval).get
  pp! system(:RoomBookingApproval_1)[:approval_required] # .should eq 2

  # _resp = exec(:approve_booking, {booking_id: 1}).get
  # system(:RoomBookingApproval_1)[:approval_required].should eq 1

  # _resp = exec(:decline_event, {booking_id: 1}).get
  # system(:RoomBookingApproval_1)[:approval_required].should eq 0
end

class CalendarMock < DriverSpecs::MockDriver
  # def update_event(event, user_id, calendar_id)
  #   pp! calendar_id
  # end

  # def decline_event(calendar_id, event_id, user_id, notify, comment)
  #   pp! calendar_id
  # end
end

class BookingsMock < DriverSpecs::MockDriver
end
