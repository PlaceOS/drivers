DriverSpecs.mock_driver "Lg::Displays::Ls5" do
  # Execute a command (triggers the connection)
  exec(:power?)
  expect_reconnect

  # connected
  # wake_on_lan(true)
  should_send("fw 01 01\r")
  responds("w 01 OK01x")
  status[:wake_on_lan].should eq(true)
  # no_signal_off(false)
  should_send("fg 01 00\r")
  responds("g 01 OK00x")
  status[:no_signal_off].should eq(false)
  # auto_off(false)
  should_send("mn 01 00\r")
  responds("n 01 OK00x")
  status[:auto_off].should eq(false)
  # local_button_lock(true)
  should_send("to 01 02\r")
  responds("o 01 OK02x")
  status[:local_button_lock].should eq(true)
  # pm_mode(3)
  should_send("sn 01 0c 03\r")
  responds("n 01 OK0c03x")
  status[:pm_mode].should eq(3)
  # do_poll && self[:connected] == true && @id_num == 1
  # screen_mute?
  should_send("kd 01 FF\r")
  responds("d 01 OK01x")
  status[:power].should eq(false)
  # input?
  should_send("xb 01 FF\r")
  responds("b 01 OKA0x")
  status[:input].should eq("Hdmi")
  # volume_mute?
  should_send("ke 01 FF\r")
  responds("e 01 OK00x")
  status[:audio_mute].should eq(true)
  # volume?
  should_send("kf 01 FF\r")
  responds("f 01 OK08x")
  status[:volume].should eq(8)

  exec(:power, true)
  # mute_video(false)
  should_send("kd 01 00\r")
  responds("d 01 OK00x")
  status[:power].should eq(true)
  # mute_audio(false)
  should_send("ke 01 01\r")
  responds("e 01 OK01x")
  status[:audio_mute].should eq(false)

  exec(:power, false)
  # mute_video(true)
  should_send("kd 01 01\r")
  responds("d 01 OK01x")
  status[:power].should eq(false)
  # mute_audio(true)
  should_send("ke 01 00\r")
  responds("e 01 OK00x")
  status[:audio_mute].should eq(true)
end
