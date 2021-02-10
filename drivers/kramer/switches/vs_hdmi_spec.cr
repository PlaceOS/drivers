DriverSpecs.mock_driver "Kramer::Switcher::VsHdmi" do
  # connected
  # get_machine_type
  # number of inputs
  should_send(Bytes[62, 0x81, 0x81, 0xFF])
  responds(Bytes[0x7E, 0x81, 0b11, 0x82])
  status[:video_inputs].should eq(3)
  # number of outputs
  should_send(Bytes[62, 0x82, 0x81, 0xFF])
  responds(Bytes[0x7E, 0x82, 0x90, 0x82])
  status[:video_outputs].should eq(16)
end
