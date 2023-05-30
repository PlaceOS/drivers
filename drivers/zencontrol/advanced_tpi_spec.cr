require "placeos-driver/spec"

DriverSpecs.mock_driver "Zencontrol::AdvancedTPI" do
  exec(:trigger, 0xFF, 1)
  should_send Bytes[0x04, 0x00, 0xA1, 0xFF, 0x00, 0x00, 0x01, 0x5B]
  responds Bytes[0xA0, 0x00, 0x00, 0xA0]
  status["area255"].should eq(1)

  exec(:lighting_scene?, {id: 2})
  should_send Bytes[0x04, 0x01, 0xAD, 66, 0x00, 0x00, 0x00, 0xea]
  responds Bytes[0xA1, 0x01, 0x01, 4, 0xA5]
  status["area2"].should eq(4)
end
