require "placeos-driver/spec"

DriverSpecs.mock_driver "Kramer::RC308Panel" do
  should_send("#RGB? 1\r")
  responds("~01@RGB 1,64,63,62,0\r\n")

  should_send("#RGB? 2\r")
  responds("~01@RGB 2,64,63,62,0\r\n")

  should_send("#RGB? 3\r")
  responds("~01@RGB 3,64,63,62,0\r\n")

  should_send("#RGB? 4\r")
  responds("~01@RGB 4,64,63,62,0\r\n")

  should_send("#RGB? 5\r")
  responds("~01@RGB 5,64,63,62,0\r\n")

  should_send("#RGB? 6\r")
  responds("~01@RGB 6,64,63,62,0\r\n")

  should_send("#RGB? 7\r")
  responds("~01@RGB 7,64,63,62,0\r\n")

  should_send("#RGB? 8\r")
  responds("~01@RGB 8,64,63,62,0\r\n")

  status["button1_light"].should be_false
  status["button2_light"].should be_false
  status["button3_light"].should be_false
  status["button4_light"].should be_false
  status["button5_light"].should be_false
  status["button6_light"].should be_false
  status["button7_light"].should be_false
  status["button8_light"].should be_false

  # Query button state
  resp = exec :button_state?, 1
  should_send("#RGB? 1\r")
  responds("~01@RGB 1,64,63,62,1\r\n")
  resp.get

  status["button1_rgb"].should eq [64, 63, 62]
  status["button1_light"].should be_true

  # Test button press
  transmit "~01@BTN 1,3,p\r\n"
  sleep 0.2
  status["button3_light"].should be_true
  status["button3_state"].should eq "Pressed"

  # Test setting button state
  resp = exec :button_state, 2, true, 3, 4, 5
  should_send("#RGB 2,3,4,5,1\r")
  responds("~01@RGB 2,3,4,5,1\r\n")
  responds("~01@RGB 2,3,4,5,1 OK\r\n")
  resp.get

  status["button2_rgb"].should eq [3, 4, 5]
  status["button2_light"].should be_true
end
