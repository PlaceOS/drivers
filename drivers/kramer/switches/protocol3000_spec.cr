DriverSpecs.mock_driver "Kramer::Switcher::Protocol3000" do
  settings({
    kramer_id: "01"
  })

  # protocol_handshake
  should_send("#\r")
  responds("~01@ OK\x0D\x0A")
  should_send("#INFO-IO?\r")
  responds("~01@ OK\x0D\x0A")

  exec(:get_machine_info)
end
