DriverSpecs.mock_driver "Wolfvision::Eye14" do
  exec(:power?)
    .should_send("\x00\x30\x00")  # power query
    .responds("\x00\x30\x01\x01") # respond with on
    .expect(status[:power]).to be(true)

  wait(150)

  exec(:power, false)
    .should_send("\x01\x30\x01\x00") # turn off device
    .responds("\x01\x30\x00")        # respond with success
    .expect(status[:power]).to be(false)

  wait(150)

  exec(:power, true)
    .should_send("\x01\x30\x01\x01") # turn off device
    .responds("\x01\x30\x00")        # respond with success
    .expect(status[:power]).to be(true)

  wait(150)

  exec(:power?)
    .should_send("\x00\x30\x00")  # power query
    .responds("\x00\x30\x01\x01") # respond with on
    .expect(status[:power]).to be(true)

  wait(150)

  exec(:zoom?)
    .should_send("\x00\x20\x00")
    .responds("\x00\x20\x02\x00\x09")
    .expect(status[:zoom]).to be(9)

  wait(150)

  exec(:zoom, 6)
    .should_send("\x01\x20\x02\x00\x06")
    .transmit("\x01\x20\x00")
    .expect(status[:zoom]).to be(6)

  wait(150)

  exec(:zoom?)
    .should_send("\x00\x20\x00")
    .responds("\x00\x20\x02\x00\x06")
    .expect(status[:zoom]).to be(6)

  wait(150)

  exec(:iris?)
    .should_send("\x00\x22\x00")
    .responds("\x00\x22\x02\x00\x20")
    .expect(status[:iris]).to be(32)

  wait(150)

  exec(:iris, 8)
    .should_send("\x01\x22\x02\x00\x08")
    .transmit("\x01\x22\x00")
    .expect(status[:iris]).to be(8)

  wait(150)

  exec(:iris?)
    .should_send("\x00\x22\x00")
    .responds("\x00\x22\x02\x00\x08")
    .expect(status[:iris]).to be(8)

  wait(150)

  exec(:autofocus?)
    .should_send("\x00\x31\x00")
    .responds("\x00\x31\x01\x00")
    .expect(status[:autofocus]).to be(false)

  wait(150)

  exec(:autofocus)
    .should_send("\x01\x31\x01\x01")
    .transmit("\x01\x31\x00") # respond with success
    .expect(status[:autofocus]).to be(true)
end
