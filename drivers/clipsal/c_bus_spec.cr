require "placeos-driver/spec"

DriverSpecs.mock_driver "Clipsal::CBus" do
  should_send("|||\r")

  transmit "\\05CA0002250109\r"
  status["area37"]?.should eq 1

  exec :set_lighting_scene, 2, {id: 37}
  should_send "\\05CA0002250208\r"
  status["area37"]?.should eq 2
end
