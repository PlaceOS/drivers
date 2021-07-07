require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Bose::ControlSpaceSerial" do
  exec(:set_parameter_group, 12)
  should_send("SS C\r")
  status[:parameter_group].should eq(12)

  exec(:get_parameter_group)
  should_send("GS\r")
  responds("S FF\r")
  status[:parameter_group].should eq(255)
end
