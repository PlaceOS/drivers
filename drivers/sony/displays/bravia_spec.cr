DriverSpecs.mock_driver "Sony::Displays::Bravia" do
  exec(:power, true)
  should_send("\x2A\x53\x43POWR0000000000000001\n")
  responds("\x2A\x53\x41POWR0000000000000000\n")
  should_send("\x2A\x53\x45POWR################\n")
  responds("\x2A\x53\x41POWR0000000000000001\n")
  status[:power].should eq(true)

  # exec(:switch_to, :hdmi)
  # should_send("\x2A\x53\x43INPT0000000100000001\n")
  # responds("\x2A\x53\x41INPT0000000000000000\n")
  # should_send("\x2A\x53\x45INPT################\n")
  # responds("\x2A\x53\x41INPT0000000100000001\n")
  # status[:input].should eq(:hdmi)
end
