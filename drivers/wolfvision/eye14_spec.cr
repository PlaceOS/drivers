DriverSpecs.mock_driver "Wolfvision::Eye14" do
  ####
  # POWER
  #
  exec(:power?)
  sleep 2.seconds
  should_send("\x00\x30\x00")    # power query
  responds("\x00\x30\x01\x00\r") # respond with off
  status[:power].should eq(false)
  #
  exec(:power, true)
  sleep 2.seconds
  should_send("\x01\x30\x01\x01") # turn on device
  responds("\x01\x30\x01\x01\r")  # respond with success
  status[:power].should eq(true)
  #
  exec(:power?)
  sleep 2.seconds
  should_send("\x00\x30\x00")    # power query
  responds("\x00\x30\x01\x01\r") # respond with on
  status[:power].should eq(true)
  #
  exec(:power, false)
  sleep 2.seconds
  should_send("\x01\x30\x01\x00") # turn off device
  responds("\x01\x30\x01\x00\r")  # respond with success
  status[:power].should eq(false)

  ####
  # ZOOM
  #
  exec(:zoom?)
  sleep 2.seconds
  should_send("\x00\x20\x00")
  responds("\x00\x20\x02\x00\x09\r") # originally zoom is 9
  status[:zoom].should eq(9)
  #
  exec(:zoom, 6)
  sleep 2.seconds
  should_send("\x01\x20\x02\x06") # set zoom to 6
  responds("\x00\x20\x02\x00\x06\r")
  status[:zoom].should eq(6)
  #
  exec(:zoom?)
  sleep 2.seconds
  should_send("\x00\x20\x00")
  responds("\x00\x20\x02\x00\x06\r")
  status[:zoom].should eq(6)

  ####
  # IRIS
  #
  exec(:iris?)
  sleep 2.seconds
  should_send("\x00\x22\x00")
  responds("\x00\x22\x02\x00\x20\r") # originally zoom is 20 hex 32 int
  status[:iris].should eq(32)
  #
  exec(:iris, 8)
  sleep 2.seconds
  should_send("\x01\x22\x02\x08") # set iris to 8
  responds("\x00\x22\x02\x00\x08\r")
  status[:iris].should eq(8)
  #
  exec(:iris?)
  sleep 2.seconds
  should_send("\x00\x22\x00")
  responds("\x00\x22\x02\x00\x08\r")
  status[:iris].should eq(8)

  ####
  # AUTOFOCUS
  #
  exec(:autofocus?)
  sleep 2.seconds
  should_send("\x00\x31\x00")
  responds("\x00\x31\x00\r")
  status[:autofocus].should eq(false)
  #
  exec(:autofocus)
  sleep 2.seconds
  should_send("\x01\x31\x01\x01")
  responds("\x01\x31\x01\x01\r")
  status[:autofocus].should eq(true)
  #
end
