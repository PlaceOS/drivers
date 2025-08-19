require "placeos-driver/spec"

DriverSpecs.mock_driver "Zoom::ZrCSAPI" do
  transmit "login: "
  should_send "echo off\r"

  exec(:bookings_list)
  should_send "zCommand Bookings List\r"
end
