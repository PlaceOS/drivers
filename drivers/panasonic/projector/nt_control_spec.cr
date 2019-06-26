EngineSpec.mock_driver "Panasonic::Projector::NTControl" do
  # Execute a command (triggers the connection)
  exec(:power?)

  # Once connected the projector will send a password salt
  expect_reconnect
  transmit "NTCONTROL 1 09b075be\r"

  # Check the request was sent with the correct password
  password = "d4a58eaea919558fb54a33a2effa8b94"
  should_send("#{password}00Q$S\r")

  # Respond with the status then check the state updated
  transmit("00PON\r")
  status[:power].should eq("On")
end
