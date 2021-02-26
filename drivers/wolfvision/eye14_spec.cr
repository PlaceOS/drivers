DriverSpecs.mock_driver "Wolfvision::Eye14" do
  #
  exec(:power?)

  # transmit "\x00\x30\x00\r"
  # transmit("\x00\x30\x00")
  # should_send("\x00\x30\x00")
  # .should_send("\x00\x30\x00")  # power query
  # responds("\x00\x30\x01\x01") # respond with on
  # power_status.should be_true
  # .expect(status[:power]).to be(true)
  # logger.info { power_status }
  sleep 150.milliseconds
  # status[:power].should be_true

  exec(:power, false)
  # .should_send("\x01\x30\x01\x00") # turn off device
  # .responds("\x01\x30\x00")        # respond with success
  # .expect(status[:power]).to be(false)

  sleep 150.milliseconds

  exec(:power, true)
  # .should_send("\x01\x30\x01\x01") # turn off device
  # .responds("\x01\x30\x00")        # respond with success
  # .expect(status[:power]).to be(true)
  sleep 150.milliseconds

  exec(:power?)
  # .should_send("\x00\x30\x00")  # power query
  # .responds("\x00\x30\x01\x01") # respond with on
  # .expect(status[:power]).to be(true)

  sleep 150.milliseconds

  exec(:zoom?)
  # .should_send("\x00\x20\x00")
  # .responds("\x00\x20\x02\x00\x09")
  # .expect(status[:zoom]).to be(9)
  sleep 150.milliseconds

  exec(:zoom, 6)
  # .should_send("\x01\x20\x02\x00\x06")
  # .transmit("\x01\x20\x00")
  # .expect(status[:zoom]).to be(6)

  sleep 150.milliseconds

  exec(:zoom?)
  # .should_send("\x00\x20\x00")
  # .responds("\x00\x20\x02\x00\x06")
  # .expect(status[:zoom]).to be(6)

  sleep 150.milliseconds

  exec(:iris?)
  # .should_send("\x00\x22\x00")
  # .responds("\x00\x22\x02\x00\x20")
  # .expect(status[:iris]).to be(32)

  sleep 150.milliseconds

  exec(:iris, 8)
  # should_send("\x01\x22\x02\x00\x08")
  # transmit("\x01\x22\x00")
  # expect(status[:iris]).to be(8)
  #

  sleep 150.milliseconds

  # status[:iris].should eq(8)

  exec(:iris?)
  # .should_send("\x00\x22\x00")
  # .responds("\x00\x22\x02\x00\x08")
  # .expect(status[:iris]).to be(8)

  sleep 150.milliseconds

  exec(:autofocus?)
  # .should_send("\x00\x31\x00")
  # .responds("\x00\x31\x01\x00")
  # .expect(status[:autofocus]).to be(false)

  sleep 150.milliseconds

  exec(:autofocus)
  # .should_send("\x01\x31\x01\x01")
  # .transmit("\x01\x31\x00") # respond with success
  # .expect(status[:autofocus]).to be(true)
end
