DriverSpecs.mock_driver "Kramer::Switcher::Protocol3000" do
  # on_load
  # state
  # protocol_handshake
  should_send("#\r")
  responds("~01@ OK\x0D\x0A")
  # get_machine_info
  should_send("#INFO-IO?\r")
  responds("~01@ OK\x0D\x0A")

  settings({
    kramer_id: "01",
    kramer_login: true,
    kramer_password: "pass"
  })
  # on_update
  # state
  # protocol_handshake
  should_send("#01@\r")
  responds("~01@ OK\x0D\x0A")
  # login
  should_send("#01@LOGIN pass\r")
  responds("~01@ OK\x0D\x0A")
  # get_machine_info
  should_send("#01@INFO-IO?\r")
  responds("~01@ OK\x0D\x0A")
end
