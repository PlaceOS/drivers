require "placeos-driver/spec"

DriverSpecs.mock_driver "Lutron::ViveBacnet" do
  system({
    BACnet: {BACnetMock},
  })

  level = exec(:level, 120.0).get
  level.should eq(100.0)
  status[:lighting_level].should eq(100.0)
end

# :nodoc:
class BACnetMock < DriverSpecs::MockDriver
  def write_real(device_id : UInt32, instance_id : UInt32, value : Float32, object_type : String = "AnalogValue")
    raise "over 100!" if value > 100.0
    self["#{device_id}.#{object_type}[#{instance_id}]"] = value
  end
end
