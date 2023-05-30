require "placeos-driver/spec"

DriverSpecs.mock_driver "Zencontrol::ClassicTPI" do
  exec(:light_level, 0x4F, 94.2)
  should_send("\x01\xFF\xFF\xFF\xFF\xFF\xFF\x4F\xF0")
  status["area79_level"].should eq(94.2)
end
