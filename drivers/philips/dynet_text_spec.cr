require "placeos-driver/spec"

DriverSpecs.mock_driver "Philips::DyNetText" do
  # Telnet establishment
  transmit "fffb01".hexbytes
  transmit "fffd01fffb03fffd03fffb05fffd05".hexbytes
  transmit "Telnet Connection Established ...\r\n\r\n"

  # Process some data
  transmit "Preset 2, Area 103, Fade 0, Join 0xff\r\n"

  # Execute some requests
  #exec :trigger, 1, 4, 320
  #should_send ""
  #status["area1"].should eq(4)
  #responds ""
end
