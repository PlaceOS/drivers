require "placeos-driver/spec"

DriverSpecs.mock_driver "Qbic::TouchPanel" do
  system({
    BACnet: {BACnetMock},
  })

  sleep 0.2

  status["power"].should eq true
  status["humidity"].should eq 34.4
end

# :nodoc:
class BACnetMock < DriverSpecs::MockDriver
  def on_load
    self["101003.AnalogValue[45]"] = true
    self["101005.AnalogValue[4]"] = 34.4
  end
end
