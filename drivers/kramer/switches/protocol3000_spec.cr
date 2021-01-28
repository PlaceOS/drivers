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

  exec(:switch_video, 1, [1, 2, 3])
  should_send("#01@VID 1>1,1>2,1>3\r")
  responds("~01@VID 1>1,1>2,1>3 OK\x0D\x0A")

  exec(:switch_audio, 2, [1, 2, 3])
  should_send("#01@AUD 2>1,2>2,2>3\r")
  responds("~01@AUD 2>1,2>2,2>3 OK\x0D\x0A")

  exec(:route, {1 => [1, 2, 3]})
  should_send("#01@ROUTE 12,1,1\r")
  responds("~01@ROUTE 12,1,1 OK\x0D\x0A")
  should_send("#01@ROUTE 12,2,1\r")
  responds("~01@ROUTE 12,2,1 OK\x0D\x0A")
  should_send("#01@ROUTE 12,3,1\r")
  responds("~01@ROUTE 12,3,1 OK\x0D\x0A")
end
