DriverSpecs.mock_driver "Sony::Displays::Bravia" do
  exec(:switch_to, :vga34)
  should_send("\x2A\x53\x43INPT0000000600000034\n")
  responds("\x2A\x53\x41INPT0000000000000000\n")
  should_send("\x2A\x53\x45INPT################\n")
  responds("\x2A\x53\x41INPT0000000600000034\n")
  expect(status[:input]).to be(:vga34)
end
