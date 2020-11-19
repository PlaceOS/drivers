DriverSpecs.mock_driver "Panasonic::Display::Protocol2" do
  # Execute a command (triggers the connection)
  exec(:power?)

  # Once connected the projector will send a password salt
  expect_reconnect
  transmit "NTCONTROL 1 09b075be\r"

  # Check the request was sent with the correct password
  password = "d4a58eaea919558fb54a33a2effa8b94"
  should_send("#{password}00QPW\r")

  # Respond with the status then check the state updated
  transmit("00PON\r")
  status[:power].should be_true


  exec(:mute?)
  expect_reconnect
  transmit "NTCONTROL 1 09b075be\r"
  should_send("#{password}00AMT\r")
  transmit("001682\r")
  status[:audio_mute].should eq(false)
end
