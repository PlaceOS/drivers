DriverSpecs.mock_driver "Sharp::PnSeries" do
  # connected
  # send_credentials
  should_send("\x0D\x0A")
  responds("OK\x0D\x0A")
  should_send("\x0D\x0A")
  responds("Password:Login incorrect\x0D\x0A")

  # Settings can only be accessed after on_load and connected
  settings({
    username: "user",
    password: "pass"
  })

  # Retrying send_credentials
  sleep 5
  should_send("user\x0D\x0A")
  responds("OK\x0D\x0A")
  should_send("pass\x0D\x0A")
  responds("Password:OK\x0D\x0A")

  exec(:do_poll)
  should_send("POWR????\x0D\x0A")
  responds("POWR 001\x0D\x0A")
  status[:warming].should eq(false)
  status[:power].should eq(true)
  should_send("INF1????\x0D\x0A")
  responds("INF1 P802B\x0D\x0A")
  status[:model_number].should eq("P802B")
  should_send("PWOD????\x0D\x0A")
  responds("PWOD 002\x0D\x0A")
  status[:power_on_delay].should eq(2)
  should_send("MUTE????\x0D\x0A")
  responds("MUTE 000\x0D\x0A")
  status[:audio_mute].should eq(false)
  should_send("VOLM????\x0D\x0A")
  responds("VOLM 010\x0D\x0A")
  status[:volume].should eq(10)

  exec(:power, false)
  should_send("POWR   0\x0D\x0A")
  responds("POWR   0\x0D\x0A")
  status[:warming].should eq(false)
  status[:power].should eq(false)
  should_send("MUTE????\x0D\x0A")
  responds("MUTE   1\x0D\x0A")
  status[:audio_mute].should eq(true)
  status[:volume].should eq(0)
end
