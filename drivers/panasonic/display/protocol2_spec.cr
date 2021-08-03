require "placeos-driver/spec"

DriverSpecs.mock_driver "Panasonic::Display::Protocol2" do
  password = "d4a58eaea919558fb54a33a2effa8b94"

  # Execute a command (triggers the connection)
  exec(:power?)
  # Once connected the projector will send a password salt
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  # Check the request was sent with the correct password
  should_send("#{password}00QPW\r")
  # Respond with the status then check the state updated
  responds("00QPW:0\r")
  status[:power].should eq(false)

  exec(:power, true)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00PON\r")
  responds("00PON\r")
  sleep 8.seconds
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00QPW\r")
  responds("00QPW:1\r")
  status[:power].should eq(true)

  exec(:switch_to, "hdmi")
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00IMS:HM1\r")
  responds("00IMS:HM1\r")
  status[:input].should eq("HDMI")

  exec(:mute?)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00AMT\r")
  responds("00AMT:0\r")
  status[:audio_mute].should eq(false)

  exec(:mute)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00AMT:1\r")
  responds("00AMT:1\r")
  status[:audio_mute].should eq(true)

  exec(:volume?)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00QAV\r")
  responds("00QAV:100\r")
  status[:volume].should eq(100)

  exec(:volume, 20)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00AVL:020\r")
  responds("00AVL:020\r")
  status[:volume].should eq(20)

  exec(:power, false)
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00POF\r")
  responds("00POF\r")
  sleep 8.seconds
  expect_reconnect
  responds("NTCONTROL 1 09b075be\r")
  should_send("#{password}00QPW\r")
  responds("00QPW:0\r")
  status[:power].should eq(false)
end
