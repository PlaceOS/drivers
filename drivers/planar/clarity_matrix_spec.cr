DriverSpecs.mock_driver "Planar::ClarityMatrix" do
  # on connect it should do_poll the device
  # should_send("op A1 display.power ? \r")
  # responds("A1 display.power ? ")
  # # status[:power].should eq(true)

  # # exec(:power)
  # # should_send("op A1 display.power = off \r")

  # # exec(:switch_to)
  # # should_send("op A1 slot.recall(0) \r")

  # transmit("OPA1DISPLAY.POWER=ON")
  # # .get.should eq("ON")
  # # responds("ON")
  # # response = exec(:received)
  
  # status["power"].should eq(false)
end
