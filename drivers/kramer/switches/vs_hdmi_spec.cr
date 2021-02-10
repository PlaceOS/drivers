DriverSpecs.mock_driver "Kramer::Switcher::VsHdmi" do
  # connected
  # get_machine_type
  # no. of video inputs
  should_send(Bytes[62, 0x81, 0x81, 0xFF])
  responds(Bytes[0x7E, 0x81, 0b1000_0011, 0x82])
  status[:video_inputs].should eq(3)
  # no. of video outputs
  should_send(Bytes[62, 0x82, 0x81, 0xFF])
  responds(Bytes[0x7E, 0x82, 0x90, 0x82])
  status[:video_outputs].should eq(16)

  exec(:switch_video, {
    5 => [8]
  })
  should_send(Bytes[1, 0x85, 0x88, 0xFF])
  status[:video8].should eq(5)

  exec(:switch_video, {
    1 => [2,3],
    4 => [5,6]
  })
  should_send(Bytes[1, 138, 144, 0xFF])
  status[:video2].should eq(1)
  status[:video3].should eq(1)
  status[:video5].should eq(4)
  status[:video6].should eq(4)

  # Command::IdentifyMachine version response
  transmit(Bytes[0x7D, 0x83, 0x85, 0x81])
end
