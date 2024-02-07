require "placeos-driver/spec"

DriverSpecs.mock_driver "Planar::ClarityMatrix" do
  # On connect it queries the state of the device
  should_send("op A1 display.power ? \r")
  responds("OPA1DISPLAY.POWER=OFF\r")

  resp = exec(:build_date?)
  should_send("ST A1 BUILD.DATE ? \r")
  responds(%(ST A1 BUILD.DATE= "JUN 15 2009 08:48:24"\r))
  resp.get.should eq "JUN 15 2009 08:48:24"

  resp = exec(:power, true)
  should_send("op A1 display.power ? \r")
  responds("OPA1DISPLAY.POWER=OFF\r")
  should_send("op ** display.power = on \r")
  sleep 3
  should_send("op A1 display.power ? \r")
  responds("OPA1DISPLAY.POWER=ON\r")
  resp.get.should eq true
end
