require "placeos-driver/spec"

DriverSpecs.mock_driver "Company3M::Displays::WallDisplay" do
  exec(:power, true)
  should_send("\x010*0E0A\x0200030001\x03\x1d\r")
  responds("\x0100*F12\x020000030000010001\x03\x6d\r")
  status[:power].should be_true

  exec(:power, false)
  should_send("\x010*0E0A\x0200030000\x03\x1c\r")
  responds("\x0100*F12\x020000030000010000\x03\x6c\r")
  status[:power].should be_false
end
