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
    kramer_id:       "01",
    kramer_login:    true,
    kramer_password: "pass",
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
  status[:video1].should eq(1)
  status[:video2].should eq(1)
  status[:video3].should eq(1)

  exec(:switch_audio, 2, [1, 2, 3])
  should_send("#01@AUD 2>1,2>2,2>3\r")
  responds("~01@AUD 2>1,2>2,2>3 OK\x0D\x0A")
  status[:audio1].should eq(2)
  status[:audio2].should eq(2)
  status[:audio3].should eq(2)

  exec(:route, {3 => [1, 2, 3]})
  should_send("#01@ROUTE 12,1,3\r")
  responds("~01@ROUTE 12,1,3 OK\x0D\x0A")
  should_send("#01@ROUTE 12,2,3\r")
  responds("~01@ROUTE 12,2,3 OK\x0D\x0A")
  should_send("#01@ROUTE 12,3,3\r")
  responds("~01@ROUTE 12,3,3 OK\x0D\x0A")
  status[:audio_video1].should eq(3)
  status[:audio_video2].should eq(3)
  status[:audio_video3].should eq(3)

  exec(:mute, true, 6)
  should_send("#01@VMUTE 6,1\r")
  responds("#01@VMUTE 6,1 OK\x0D\x0A")
  status[:video6_muted].should eq(true)
  should_send("#01@MUTE 6,1\r")
  responds("#01@MUTE 6,1 OK\x0D\x0A")
  status[:audio6_muted].should eq(true)
end
