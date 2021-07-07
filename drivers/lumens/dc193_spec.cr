require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Lumens::DC193" do
  # On connect it queries the state of the device
  should_send(Bytes[0xA0, 0xB7, 0x00, 0x00, 0x00, 0xAF])
  transmit(Bytes[0xA0, 0xB7, 0x01, 0x00, 0x00, 0xAF])

  status[:ready].should be_true
  status[:power].should be_false
end
